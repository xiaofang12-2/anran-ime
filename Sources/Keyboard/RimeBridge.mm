#import "RimeBridge.h"

#include "rime_api.h"

#include <cstring>
#include <string.h>
#include <string>

@implementation AnRanRimeCandidate
@end

@implementation AnRanRimeBridge {
    RimeApi *_api;
    RimeSessionId _session;
    BOOL _initialized;
    BOOL _ready;
    NSRecursiveLock *_lock;

    // librime 的 traits 只借用这些 C 字符串，必须活到 initialize 之后 ——
    // 存成 ivar，别让局部 std::string 出作用域把 c_str() 悬空了。
    std::string _sharedDir;
    std::string _userDir;
    std::string _buildDir;
    std::string _stagingDir;
    std::string _distName;
    std::string _distCode;
    std::string _distVer;
    std::string _appName;

    // 自检结果：方案 id 空 = 方案没加载上（候选必为 0，上层退回自研）；
    // probeCount = 打「nihao」实际能出多少条候选。这两个数是排查引擎问题的唯一抓手。
    NSString *_schemaId;
    NSInteger _probeCount;
}

- (instancetype)initWithSharedDataDir:(NSString *)sharedDataDir
                          userDataDir:(NSString *)userDataDir {
    self = [super init];
    if (self) {
        _sharedDir = std::string(sharedDataDir.UTF8String ?: "");
        _userDir = std::string(userDataDir.UTF8String ?: "");
        _buildDir = _sharedDir + "/build";
        // staging 是 librime 部署产物的落点，默认值就是 ${user_data_dir}/build。
        // 显式指死：随包预编译的 bin 在 ${shared}/build，部署时按「校验和」判断
        // 表没变就直接复用，不会现场重编那 60MB 词库（扩展内存扛不住）。
        _stagingDir = _userDir + "/build";
        _distName = "AnRanIME";
        _distCode = "anran-ime";
        _distVer = "1.0";
        _appName = "rime.anranime";
        _schemaId = @"";
        _probeCount = 0;
        _session = 0;
        _initialized = NO;
        _ready = NO;
        _lock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_lock lock];
    if (_api && _session != 0) {
        _api->destroy_session(_session);
        _session = 0;
    }
    [_lock unlock];
}

#pragma mark - 初始化 / 部署

- (BOOL)setupAndDeploy {
    [_lock lock];
    BOOL ok = NO;
    @try {
        if (!_initialized) {
            _api = rime_get_api();
            if (_api == NULL) {
                [_lock unlock];
                return NO;
            }

            RimeTraits traits = {0};
            RIME_STRUCT_INIT(RimeTraits, traits);
            traits.shared_data_dir = _sharedDir.c_str();
            traits.user_data_dir = _userDir.c_str();
            traits.distribution_name = _distName.c_str();
            traits.distribution_code_name = _distCode.c_str();
            traits.distribution_version = _distVer.c_str();
            traits.app_name = _appName.c_str();
            traits.prebuilt_data_dir = _buildDir.c_str();
            traits.staging_dir = _stagingDir.c_str();
            traits.min_log_level = 3;   // 只留 FATAL，扩展里别刷日志

            if (RIME_API_AVAILABLE(_api, setup)) {
                _api->setup(&traits);
            }
            _api->initialize(&traits);
            _initialized = YES;

            // 只有随包带了预编译 bin 才走 maintenance（这一步只是把 bin 落到
            // 可写目录，很快）。没 bin 时若调 start_maintenance，librime 会现场
            // 编译整份词库 —— 键盘扩展内存只有 30~60MB，必被 jetsam 杀掉。
            // 宁可不部署、退回自研引擎，也不能把扩展搞崩。
            if ([self hasPrebuiltBins] && RIME_API_AVAILABLE(_api, start_maintenance)) {
                _api->start_maintenance(False);
                // 不管 start_maintenance 返回值都 join：返回 False 只表示「没排到
                // 部署任务」，join 一个没启动的工作线程是安全的。少 join 一次就可能
                // 拿到「会话建了、方案还没落地」的半成品 —— 那正是候选为零的来源。
                if (RIME_API_AVAILABLE(_api, join_maintenance_thread)) {
                    _api->join_maintenance_thread();
                }
            }
        }
        ok = [self createSessionLocked];
        if (ok) { [self probeLocked]; }
    } @catch (...) {
        ok = NO;
    }
    // 方案没加载上 = 候选必然为 0，别让上层以为引擎可用（那样每敲一键都白跑一趟）。
    _ready = ok && _schemaId.length > 0;
    [_lock unlock];
    return _ready;
}

/// 自检：读当前方案 id，再打一个常用拼音数一下真实候选条数。
///
/// 光看 create_session 成功判断不了引擎死活 —— 方案没加载上照样能建会话，
/// 但一条候选都不出。所以必须拿真实输入探一次，这两个数是排查的唯一抓手。
- (void)probeLocked {
    _schemaId = @"";
    _probeCount = 0;
    if (_api == NULL || _session == 0) { return; }
    @try {
        if (RIME_API_AVAILABLE(_api, get_status)) {
            RimeStatus st = {0};
            RIME_STRUCT_INIT(RimeStatus, st);
            if (_api->get_status(_session, &st)) {
                if (st.schema_id) {
                    _schemaId = [NSString stringWithUTF8String:st.schema_id] ?: @"";
                }
                if (RIME_API_AVAILABLE(_api, free_status)) { _api->free_status(&st); }
            }
        }
        if (RIME_API_AVAILABLE(_api, set_input) && RIME_API_AVAILABLE(_api, get_context)) {
            _api->set_input(_session, "nihao");
            RimeContext ctx = {0};
            RIME_STRUCT_INIT(RimeContext, ctx);
            if (_api->get_context(_session, &ctx)) {
                _probeCount = ctx.menu.num_candidates;
                _api->free_context(&ctx);
            }
            if (RIME_API_AVAILABLE(_api, clear_composition)) {
                _api->clear_composition(_session);
            }
        }
    } @catch (...) {
        _probeCount = 0;
    }
}

/// 预编译 bin 是否随包带进来了（rime/build/*.bin）。
/// 没有就别走 maintenance —— 现场编译会把扩展内存打爆。
- (BOOL)hasPrebuiltBins {
    NSString *build = [NSString stringWithUTF8String:_buildDir.c_str()];
    if (build.length == 0) { return NO; }
    NSArray<NSString *> *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:build error:nil];
    for (NSString *f in files) {
        if ([f hasSuffix:@".bin"]) { return YES; }
    }
    return NO;
}

- (BOOL)createSessionLocked {
    if (_api == NULL) { return NO; }
    if (_session != 0) {
        if (RIME_API_AVAILABLE(_api, find_session) && _api->find_session(_session)) {
            return YES;
        }
    }
    _session = _api->create_session();
    if (_session == 0) { return NO; }

    // 优先雾凇拼音（rime-ice，社区里最接近百度的免费方案）；
    // 没打进去就退回鼠须管自带的 luna_pinyin_simp，再不行 luna_pinyin。
    if (RIME_API_AVAILABLE(_api, select_schema)) {
        if (!_api->select_schema(_session, "rime_ice")) {
            if (!_api->select_schema(_session, "luna_pinyin_simp")) {
                _api->select_schema(_session, "luna_pinyin");
            }
        }
    }
    // 兜底保证出简体：luna_pinyin_simp 本来就简化，luna_pinyin 得靠这个开关。
    // 开关不在方案里时 librime 会静默忽略，不报错。
    if (RIME_API_AVAILABLE(_api, set_option)) {
        _api->set_option(_session, "simplification", True);
        _api->set_option(_session, "ascii_mode", False);
    }
    return YES;
}

- (BOOL)isReady {
    [_lock lock];
    BOOL r = _ready;
    [_lock unlock];
    return r;
}

/// 当前方案 id（空 = 方案没加载上，候选必为 0）
- (NSString *)activeSchemaId {
    [_lock lock];
    NSString *s = _schemaId ?: @"";
    [_lock unlock];
    return s;
}

/// 打「nihao」实际能出的候选条数（0 = 引擎没在干活）
- (NSInteger)probeCandidateCount {
    [_lock lock];
    NSInteger n = _probeCount;
    [_lock unlock];
    return n;
}

- (NSString *)rimeVersion {
    [_lock lock];
    NSString *v = @"";
    if (_api && RIME_API_AVAILABLE(_api, get_version)) {
        const char *s = _api->get_version();
        if (s) { v = [NSString stringWithUTF8String:s] ?: @""; }
    }
    [_lock unlock];
    return v;
}

- (BOOL)selectSchema:(NSString *)schemaId {
    [_lock lock];
    BOOL ok = NO;
    if (_ready && _api && _session != 0 && RIME_API_AVAILABLE(_api, select_schema)) {
        ok = _api->select_schema(_session, schemaId.UTF8String);
    }
    [_lock unlock];
    return ok;
}

- (void)setOption:(NSString *)name value:(BOOL)value {
    [_lock lock];
    if (_ready && _api && _session != 0 && RIME_API_AVAILABLE(_api, set_option)) {
        _api->set_option(_session, name.UTF8String, value ? True : False);
    }
    [_lock unlock];
}

#pragma mark - 候选

- (NSArray<AnRanRimeCandidate *> *)candidatesForInput:(NSString *)input
                                                limit:(NSInteger)limit {
    NSMutableArray<AnRanRimeCandidate *> *out = [NSMutableArray array];
    [_lock lock];
    if (!_ready || _api == NULL || _session == 0) {
        [_lock unlock];
        return out;
    }
    @try {
        if (input.length == 0) {
            if (RIME_API_AVAILABLE(_api, clear_composition)) {
                _api->clear_composition(_session);
            }
            [_lock unlock];
            return out;
        }
        if (!RIME_API_AVAILABLE(_api, set_input)) {
            [_lock unlock];
            return out;
        }
        _api->set_input(_session, input.UTF8String);

        RimeContext ctx = {0};
        RIME_STRUCT_INIT(RimeContext, ctx);
        if (_api->get_context(_session, &ctx)) {
            int n = ctx.menu.num_candidates;
            for (int i = 0; i < n && i < (int)limit; i++) {
                RimeCandidate c = ctx.menu.candidates[i];
                AnRanRimeCandidate *rc = [[AnRanRimeCandidate alloc] init];
                rc.text = c.text ? ([NSString stringWithUTF8String:c.text] ?: @"") : @"";
                rc.comment = c.comment ? ([NSString stringWithUTF8String:c.comment] ?: @"") : @"";
                if (rc.text.length > 0) { [out addObject:rc]; }
            }
            _api->free_context(&ctx);
        }
    } @catch (...) {
        [out removeAllObjects];
    }
    [_lock unlock];
    return out;
}

- (NSString *)currentInput {
    [_lock lock];
    NSString *s = @"";
    if (_ready && _api && _session != 0 && RIME_API_AVAILABLE(_api, get_input)) {
        const char *in = _api->get_input(_session);
        if (in) { s = [NSString stringWithUTF8String:in] ?: @""; }
    }
    [_lock unlock];
    return s;
}

- (nullable NSString *)selectCandidateAtIndex:(NSInteger)index {
    NSString *result = nil;
    [_lock lock];
    if (_ready && _api && _session != 0 && RIME_API_AVAILABLE(_api, select_candidate)) {
        @try {
            if (_api->select_candidate(_session, (size_t)index)) {
                RimeCommit commit = {0};
                RIME_STRUCT_INIT(RimeCommit, commit);
                if (_api->get_commit(_session, &commit)) {
                    if (commit.text) {
                        result = [NSString stringWithUTF8String:commit.text];
                    }
                    _api->free_commit(&commit);
                }
            }
        } @catch (...) {
            result = nil;
        }
    }
    [_lock unlock];
    return result;
}

- (void)learnWord:(NSString *)word input:(NSString *)input {
    if (word.length == 0 || input.length == 0) { return; }
    [_lock lock];
    if (_ready && _api && _session != 0 && RIME_API_AVAILABLE(_api, set_input)) {
        @try {
            _api->set_input(_session, input.UTF8String);
            NSInteger hit = -1;
            RimeContext ctx = {0};
            RIME_STRUCT_INIT(RimeContext, ctx);
            if (_api->get_context(_session, &ctx)) {
                for (int i = 0; i < ctx.menu.num_candidates; i++) {
                    const char *t = ctx.menu.candidates[i].text;
                    if (t && [word isEqualToString:[NSString stringWithUTF8String:t]]) {
                        hit = i;
                        break;
                    }
                }
                _api->free_context(&ctx);
            }
            if (hit >= 0 && RIME_API_AVAILABLE(_api, select_candidate)) {
                // 选中即让 librime 把这条学进用户词典；上屏文本我们丢掉，
                // 真正的上屏由键盘自己那套做，别重复吐字。
                _api->select_candidate(_session, (size_t)hit);
                RimeCommit commit = {0};
                RIME_STRUCT_INIT(RimeCommit, commit);
                if (_api->get_commit(_session, &commit)) {
                    _api->free_commit(&commit);
                }
            } else if (RIME_API_AVAILABLE(_api, clear_composition)) {
                _api->clear_composition(_session);
            }
        } @catch (...) {
            // 学词失败不影响打字
        }
    }
    [_lock unlock];
}

- (void)reset {
    [_lock lock];
    if (_ready && _api && _session != 0 && RIME_API_AVAILABLE(_api, clear_composition)) {
        _api->clear_composition(_session);
    }
    [_lock unlock];
}

@end

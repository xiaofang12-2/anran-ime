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
    std::string _distName;
    std::string _distCode;
    std::string _distVer;
    std::string _appName;
}

- (instancetype)initWithSharedDataDir:(NSString *)sharedDataDir
                          userDataDir:(NSString *)userDataDir {
    self = [super init];
    if (self) {
        _sharedDir = std::string(sharedDataDir.UTF8String ?: "");
        _userDir = std::string(userDataDir.UTF8String ?: "");
        _buildDir = _sharedDir + "/build";
        _distName = "AnRanIME";
        _distCode = "anran-ime";
        _distVer = "1.0";
        _appName = "rime.anranime";
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
            traits.min_log_level = 3;   // 只留 FATAL，扩展里别刷日志

            if (RIME_API_AVAILABLE(_api, setup)) {
                _api->setup(&traits);
            }
            _api->initialize(&traits);
            _initialized = YES;

            // 有预编译 bin 时这一步只是把 bin 落到可写目录，很快；
            // 没有就现场编译（慢，但不至于起不来）。
            if (RIME_API_AVAILABLE(_api, start_maintenance)) {
                Bool need = _api->start_maintenance(False);
                if (need && RIME_API_AVAILABLE(_api, join_maintenance_thread)) {
                    _api->join_maintenance_thread();
                }
            }
        }
        ok = [self createSessionLocked];
    } @catch (...) {
        ok = NO;
    }
    _ready = ok;
    [_lock unlock];
    return ok;
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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一条 Rime 候选（librime 原生输出）
@interface AnRanRimeCandidate : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *comment;
@end

/// librime 薄封装。
///
/// 只做一件事：把 librime 的 C API（通过 `rime_get_api()` 拿到的结构体指针）
/// 暴露成 ObjC 方法给 Swift 调。所有 API 调用都在同一把锁里串行化 ——
/// librime 的会话不是线程安全的，键盘里主线程和后台部署线程都会碰到它。
///
/// 这是 iRime / 仓输入法那套做法：librime 静态链进扩展、同进程调用。
/// 不是 XPC（iOS 第三方键盘拿不到 IPC 通道，见 docs/ARCHITECTURE.md §0.1）。
@interface AnRanRimeBridge : NSObject

- (instancetype)initWithSharedDataDir:(NSString *)sharedDataDir
                          userDataDir:(NSString *)userDataDir;

/// 初始化 + 部署 + 建会话。可能耗时（首次要把预编译 bin 落到可写目录），
/// 调用方负责放后台线程。返回是否就绪。
- (BOOL)setupAndDeploy;

- (BOOL)isReady;
- (NSString *)rimeVersion;

/// 切方案（如 luna_pinyin_simp）。失败返回 NO，保留原方案。
- (BOOL)selectSchema:(NSString *)schemaId;

/// 设置运行期选项，如 ascii_mode / simplification / traditionalization。
- (void)setOption:(NSString *)name value:(BOOL)value;

/// 设输入串，取候选。热路径，内部无磁盘 IO。
- (NSArray<AnRanRimeCandidate *> *)candidatesForInput:(NSString *)input
                                                limit:(NSInteger)limit;

/// 当前会话里未消化的输入串（上屏部分后剩下的）。
- (NSString *)currentInput;

/// 选中第 index 条候选，返回上屏文本；没上屏返回 nil。
/// 副作用：librime 会把这词学进用户词典。
- (nullable NSString *)selectCandidateAtIndex:(NSInteger)index;

/// 让 librime 学习「input -> word」：在候选里找到同词那条并选中一次，
/// 上屏文本丢弃（真正上屏由我们自己做）。找不到就不动。
- (void)learnWord:(NSString *)word input:(NSString *)input;

/// 清空当前组字
- (void)reset;

@end

NS_ASSUME_NONNULL_END

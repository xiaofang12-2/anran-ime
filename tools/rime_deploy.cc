// CI 专用：在 macOS 上把 Rime 方案的 yaml 编译成 .bin（table/prism/reverse…）。
//
// 为什么不直接用鼠须管自带的 rime_deployer：那个跟运行时的 librime 不是同一版，
// .table.bin / .prism.bin 的格式可能对不上，运行时加载失败就得现场重编，
// 而键盘扩展内存只有 30~60MB，现场编必被 jetsam 杀。
// 这里用跟 App 里静态链接的**同一份 librime**（macos 切片）来编，
// 产物格式与运行时严格一致，拿来就能用。
//
// 用法：rime_deploy <shared_dir> <user_dir>
// 编好的 bin 落在 <user_dir>/build/，调用方再拷到 <shared>/build/。

#include "rime_api.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: rime_deploy <shared_dir> <user_dir>\n");
    return 2;
  }

  RimeApi *api = rime_get_api();
  if (api == NULL) {
    fprintf(stderr, "rime_get_api() returned NULL\n");
    return 3;
  }

  RimeTraits traits;
  memset(&traits, 0, sizeof(traits));
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.distribution_name = "AnRanIME";
  traits.distribution_code_name = "anran-ime";
  traits.distribution_version = "1.0";
  traits.app_name = "rime.anranime";
  traits.min_log_level = 1;

  if (RIME_API_AVAILABLE(api, setup)) {
    api->setup(&traits);
  }
  api->initialize(&traits);

  Bool need = False;
  if (RIME_API_AVAILABLE(api, start_maintenance)) {
    need = api->start_maintenance(True);  // full_check：不管旧 bin 在不在都重编
    if (RIME_API_AVAILABLE(api, join_maintenance_thread)) {
      api->join_maintenance_thread();
    }
  }

  if (RIME_API_AVAILABLE(api, finalize)) {
    api->finalize();
  }

  printf("deploy done, full_check_required=%d\n", need);
  return 0;
}

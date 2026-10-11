// CI 专用：在 macOS 上把 Rime 方案的 yaml 编译成 .bin（table/prism/reverse…）。
//
// 为什么不直接用鼠须管自带的 rime_deployer：那个跟运行时的 librime 不是同一版，
// .table.bin / .prism.bin 的格式可能对不上，运行时加载失败就得现场重编，
// 而键盘扩展内存只有 30~60MB，现场编必被 jetsam 杀。
// 这里用跟 App 里静态链接的**同一份 librime**（macos 切片）来编，
// 产物格式与运行时严格一致，拿来就能用。
//
// 用法：rime_deploy <shared_dir> <user_dir>
// 编好的 bin 落在 <shared_dir>/build/（prebuilt_data_dir），调用方直接带走。

#include "rime_api.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static int dir_has_bin(const char *dir) {
  // 粗略数一下目录里有没有 *.bin
  char cmd[1024];
  snprintf(cmd, sizeof(cmd), "ls \"%s\"/*.bin 2>/dev/null | wc -l", dir);
  FILE *p = popen(cmd, "r");
  if (!p) return 0;
  int n = 0;
  if (fscanf(p, "%d", &n) != 1) n = 0;
  pclose(p);
  return n;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: rime_deploy <shared_dir> <user_dir>\n");
    return 2;
  }

  char prebuilt[1024];
  char staging[1024];
  snprintf(prebuilt, sizeof(prebuilt), "%s/build", argv[1]);
  snprintf(staging, sizeof(staging), "%s/build", argv[2]);
  mkdir(prebuilt, 0755);
  mkdir(staging, 0755);

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
  // 显式指死：编出来的 bin 直接落到 <shared>/build，运行时也是读这里。
  traits.prebuilt_data_dir = prebuilt;
  traits.staging_dir = staging;

  if (RIME_API_AVAILABLE(api, setup)) {
    api->setup(&traits);
  }
  api->initialize(&traits);

  if (RIME_API_AVAILABLE(api, get_version)) {
    const char *v = api->get_version();
    printf("librime version: %s\n", v ? v : "(null)");
  }

  Bool need = False;
  if (RIME_API_AVAILABLE(api, start_maintenance)) {
    need = api->start_maintenance(True);  // full_check：不管旧 bin 在不在都重编
    printf("start_maintenance(full_check) -> need=%d\n", need);
    if (RIME_API_AVAILABLE(api, join_maintenance_thread)) {
      api->join_maintenance_thread();
      printf("join_maintenance_thread done\n");
    }
  } else {
    printf("start_maintenance NOT AVAILABLE in this librime build\n");
  }

  int n = dir_has_bin(prebuilt);
  printf("prebuilt dir %s has %d bin file(s)\n", prebuilt, n);
  int m = dir_has_bin(staging);
  printf("staging dir %s has %d bin file(s)\n", staging, m);

  if (RIME_API_AVAILABLE(api, finalize)) {
    api->finalize();
  }

  printf("deploy done, full_check_required=%d\n", need);
  return n > 0 ? 0 : 4;   // 没产出 bin 就当失败，让脚本走兜底
}

// 打包前预先编译 Rime 方案和词库（librime 静态编译时不带 rime_deployer）。
// 只在开发者电脑上运行，不放进 App。
// 用法：rime_prebuild <shared_data_dir> <user_data_dir> <staging_dir>
#include <stdio.h>
#include "rime_api.h"

int main(int argc, char *argv[]) {
  if (argc < 4) {
    fprintf(stderr, "usage: rime_prebuild <shared_data_dir> <user_data_dir> <staging_dir>\n");
    return 2;
  }
  RimeApi *api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.staging_dir = argv[3];
  traits.prebuilt_data_dir = argv[3];
  traits.distribution_name = "SayFlow";
  traits.distribution_code_name = "SayFlow";
  traits.distribution_version = "2.0.0";
  traits.app_name = "rime.sayflow.prebuild";
  api->setup(&traits);
  api->deployer_initialize(&traits);
  Bool ok = api->deploy();
  api->finalize();
  printf("rime_prebuild: %s\n", ok ? "ok" : "failed");
  return ok ? 0 : 1;
}

QT_CPU_FEATURES.x86_64 = cx16 popcnt sse3 ssse3 sse4.1 sse4.2 sse4
QT.global_private.enabled_features = reduce_exports x86intrin sse2 sse3 ssse3 sse4_1 sse4_2 avx f16c avx2 avx512f avx512er avx512cd avx512pf avx512dq avx512bw avx512vl avx512ifma avx512vbmi avx512vbmi2 aesni vaes rdrnd rdseed shani localtime_r posix_fallocate alloca_h alloca gui network printsupport widgets xml dlopen relocatable intelcet glibc_fortify_source stack_protector stack_clash_protection libstdcpp_assertions relro_now_linker largefile precompile_header enable_new_dtags sse2 sse3 ssse3 sse4_1 sse4_2 avx f16c avx2 avx512f avx512er avx512cd avx512pf avx512dq avx512bw avx512vl avx512ifma avx512vbmi avx512vbmi2 aesni vaes rdrnd rdseed shani
QT.global_private.disabled_features = use_bfd_linker use_gold_linker use_lld_linker use_mold_linker android-style-assets gc_binaries developer-build private_tests debug elf_private_full_version no_direct_extern_access mips_dsp mips_dspr2 neon arm_crc32 arm_crypto localtime_s alloca_malloc_h system-zlib stdlib-libcpp dbus dbus-linked sql testlib libudev openssl trivial_auto_var_init_pattern libcpp_hardening
CONFIG += largefile precompile_header enable_new_dtags sse2 sse3 ssse3 sse4_1 sse4_2 avx f16c avx2 avx512f avx512er avx512cd avx512pf avx512dq avx512bw avx512vl avx512ifma avx512vbmi avx512vbmi2 aesni vaes rdrnd rdseed shani
PKG_CONFIG_EXECUTABLE = /usr/bin/pkg-config
QT_COORD_TYPE = double
QT_BUILD_PARTS = libs tools

QMAKE_LIBS_ZLIB = -lz
QMAKE_LIBS_ZSTD = -lzstd

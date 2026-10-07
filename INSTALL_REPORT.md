# libROM 安装总结报告

> 生成日期：2026-10-07
> 维护方式：由 `install_librom.sh` 自动复现，本报告为该次安装的完整记录，供后续查阅。

## 1. 概要

| 项目 | 内容 |
|---|---|
| libROM 版本 | 上游最新提交 `4de3620`（Add no hyper reduction mode to Mixed Nonlinear Diffusion, #321），含 #320 CMake 重构（C++17） |
| 安装模式 | 全功能构建（此前为 core-only 静态库） |
| 主产物 | `build/lib/libROM.so`（共享库，含 MFEM 接口）+ `build_pic/lib/libROM.a`（PIC 静态核心，供 SU2） |
| 新建依赖 | HYPRE 2.28.0、ParMETIS 4.0.3（PIC 重建）、MFEM 4.7 并行共享库、googletest 1.14.0 |
| 复用依赖 | ScaLAPACK 2.2.0（已是 PIC）、flexi 并行 HDF5 1.12.0（build/ 共享库构建用）、系统 OpenBLAS |
| 验证结果 | `ctest` 29/29 通过（含 10 个 MPI 并行测试）；双库冒烟测试通过；SU2 端到端 ROM 算例矩阵通过（见 §10） |
| 关键变化 | libROM 现要求 **C++17**；MFEM/HYPRE/parmetis/metis 全链路可用；脚本幂等可重跑 |
| SU2 对齐 | `build_pic/lib/libROM.a` 已对齐 SU2 vendor HDF5 1.12.1（libsu2hdf5.a）——H5check_version 要求同版本，见 §10 |

## 2. 环境与工具链

| 组件 | 版本/路径 |
|---|---|
| 操作系统 | Ubuntu 22.04（内核 6.8.0），x86_64，16 核 |
| 编译器 | gcc/g++ 11.4.0，经 MPI 包装器使用 |
| MPI | OpenMPI（`/usr/bin/mpicc`、`mpicxx`、`mpif90`），MPI 3.1 |
| CMake | 3.30.5（`/usr/local/bin/cmake`，要求 ≥ 3.12） |
| BLAS/LAPACK | 系统 OpenBLAS（`/usr/lib/x86_64-linux-gnu/libopenblas.so`，同时提供 BLAS 与 LAPACK） |
| HDF5 | 1.12.0 **并行版**（flexi 构建）用于 build/ 共享库；build_pic 经 Step 8b 对齐为 SU2 vendor 1.12.1（见 §10）。flexi 路径：`/home/tang/packages/flexi/share/GNU-MPI/HDF5/build/src/HDF5-build` |

> 注意：`cmake/toolchains/default-toss_4_x86_64_ib-librom-dev.cmake` 是 LLNL TOSS4 机器专用
> （Intel MKL、BLA_VENDOR=Intel10_64lp），本机**不使用** toolchain，编译器以 `-DCMAKE_*_COMPILER` 直接传入。

## 3. 目录结构

```
libROM/
├── build/                          # 全功能共享库构建（USE_MFEM=ON）
│   ├── lib/libROM.so               #   主共享库（2.5 MB）
│   ├── include/                    #   make install 的头文件树（librom.h、linalg/、algo/、
│   │                               #   hyperreduction/、utils/、mfem/、CAROM_config.h、FCMangle.h）
│   ├── tests/                      #   单元测试可执行文件（ctest 在此运行）
│   └── examples/ … regression_tests/
├── build_pic/                      # PIC 静态核心构建（USE_MFEM=OFF，供 SU2）
│   ├── lib/libROM.a                #   静态库（7.9 MB，已验证 0 个非 PIC 重定位）
│   └── include/                    #   头文件树
├── dependencies/
│   ├── scalapack-2.2.0/libscalapack.a    # ScaLAPACK 静态库（5.6 MB，-fPIC）
│   ├── hypre/src/hypre/{lib,include}     # HYPRE 安装位置（libHYPRE.a 6.2 MB）
│   ├── parmetis-4.0.3/build/lib → Linux-x86_64
│   │       ├── libparmetis/libparmetis.so  (0.55 MB)
│   │       └── libmetis/libmetis.a         (0.67 MB，metis 5.1.0，-fPIC)
│   ├── mfem_parallel/                    # MFEM 源码 + libmfem.so.4.7（22 MB）
│   ├── mfem → mfem_parallel              # 符号链接（libROM CMake 查找路径）
│   └── googletest/install/               # libgtest.a 等
├── install_librom.sh               # 一键安装脚本（幂等）
└── librom_env.sh                   # 环境变量脚本（由安装脚本生成）
```

## 4. 依赖组件构建明细

### 4.1 ScaLAPACK 2.2.0（复用）

- 产物：`dependencies/scalapack-2.2.0/libscalapack.a`
- 由 `dependencies/SLmake.inc` 驱动 `make`，编译选项已含 `-fPIC`
  （`FCFLAGS="-O3 -fallow-argument-mismatch -fPIC"`、`CCFLAGS="-O3 -fPIC"`）。
- 必须是 PIC：它会被链入共享库 `libROM.so`。
- CMake 通过环境变量 `SCALAPACKDIR` 发现它（见 `cmake/modules/FindScaLAPACK.cmake`）。

### 4.2 HYPRE 2.28.0（本次新建）

```bash
cd dependencies
tar -xzf v2.28.0.tar.gz && mv hypre-2.28.0 hypre
cd hypre/src
CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" ./configure --disable-fortran CC=mpicc CXX=mpicxx
make -j16
```

- 安装位置（autotools 默认）：`dependencies/hypre/src/hypre/{lib,include}`。
- 该路径同时是 MFEM 默认查找路径（`../hypre/src/hypre`）和 libROM CMake 的 hint 路径，三方一致。
- 静态库嵌入 `libmfem.so`，故必须 `-fPIC`。

### 4.3 ParMETIS 4.0.3（PIC 重建）

```bash
cd dependencies/parmetis-4.0.3
rm -rf build
CFLAGS="-fPIC -O3" make config shared=1 cc=mpicc cxx=mpicxx
make -j16
( cd build && ln -sfn Linux-x86_64 lib )
```

- 与上游 `scripts/setup.sh` 完全一致（`shared=1`），额外通过 `CFLAGS` 保证
  `libmetis.a`（metis 5.1.0）为 PIC——否则它无法链入 `libmfem.so`。
- 产物布局：`build/lib/libparmetis/libparmetis.so`、`build/lib/libmetis/libmetis.a`
  （MFEM 的 `METIS_LIB` 与 libROM CMake 的 hint 都指向这两个目录）。
- **必须显式传 `-DPARMETIS_DIR=<…>/build/lib`**：否则 libROM CMake 里
  `find_library(PARMETIS … HINTS "${PARMETIS_DIR}/lib" …)` 会因 `PARMETIS_DIR` 为空
  得到 hint `/lib`，从而命中系统的 `libparmetis-dev`（`/lib/libparmetis.so`）。

### 4.4 MFEM 4.7（本次首次编译成功）

```bash
cd dependencies/mfem_parallel
make -j16 parallel CPPFLAGS="-fPIC" STATIC=NO SHARED=YES \
     MFEM_USE_MPI=YES MFEM_USE_GSLIB=NO MFEM_USE_LAPACK=NO \
     MFEM_USE_METIS=YES MFEM_USE_METIS_5=YES \
     METIS_DIR="$(pwd)/../parmetis-4.0.3" \
     METIS_OPT="-I$(pwd)/../parmetis-4.0.3/metis/include" \
     METIS_LIB="-L…/build/lib/libparmetis -lparmetis -L…/build/lib/libmetis -lmetis" \
     MFEM_USE_SUPERLU=NO SUPERLU_DIR= SUPERLU_OPT= SUPERLU_LIB=
```

- 版本锁定 v4.7（`tags/v4.7-0-gdc9128ef…`，与 PyMFEM 4.7.0.1 匹配）。
- 产物：`libmfem.so.4.7` + 符号链接 `libmfem.so`；随后建 `dependencies/mfem → mfem_parallel`。
- `config/config.mk` 即上述参数的固化结果；HYPRE 路径为 MFEM 默认值（无需显式传入）。
- libROM 链接 `libmfem.so`，其 NEEDED 依赖 `libparmetis.so` 运行时由系统
  `libparmetis-dev`（同为 4.0.3）或 `LD_LIBRARY_PATH` 中的本地目录解析，二者一致可用。

### 4.5 googletest 1.14.0（单元测试，可选）

```bash
curl -sL -o v1.14.0.tar.gz https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz
cmake googletest-1.14.0 -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=…/install
make -j16 && make install
```

- 以 `-DGTest_ROOT=dependencies/googletest/install` 传给 libROM CMake（CMP0074 生效）。
- 若不可用（如离线），安装脚本自动降级为 `ENABLE_TESTS=OFF`。

## 5. libROM 本体构建（双构建）

### 5.1 全功能共享库 → `build/`

```bash
export SCALAPACKDIR=dependencies/scalapack-2.2.0
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DUSE_MFEM=ON -DMFEM_USE_GSLIB=OFF -DBUILD_STATIC=OFF \
         -DENABLE_EXAMPLES=ON -DENABLE_TESTS=ON \
         -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_Fortran_COMPILER=mpif90 \
         -DHDF5_ROOT=/home/tang/packages/flexi/share/GNU-MPI/HDF5/build/src/HDF5-build \
         -DGTest_ROOT=dependencies/googletest/install \
         -DPARMETIS_DIR=dependencies/parmetis-4.0.3/build/lib \
         -DCMAKE_INSTALL_PREFIX=build
make -j16 && make install
```

- CMake 实际解析结果：BLAS/LAPACK=OpenBLAS、HDF5=flexi 1.12.0（并行）、
  MFEM=`dependencies/mfem/libmfem.so`、HYPRE=`dependencies/hypre/src/hypre/lib/libHYPRE.a`、
  METIS=`dependencies/parmetis-4.0.3/build/lib/libmetis/libmetis.a`、
  ScaLAPACK=`dependencies/scalapack-2.2.0/libscalapack.a`。
- `make install`（prefix=build）只安装头文件到 `build/include`（库本身已在 `build/lib`）。
- 功能覆盖：SVD（static/incremental standard/Brand/randomized）、DMD/DMDc/Adaptive/
  Nonuniform/Snapshot/Parametric DMD、DEIM/GNAT/QDEIM/S_OPT/STSampling、
  GreedySampler 系列、流形插值（Matrix/Vector/PCHIP）、MFEM 接口、
  HDF5（并行 MPI-IO）与 CSV 数据库、示例与回归测试。

### 5.2 PIC 静态核心 → `build_pic/`

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DUSE_MFEM=OFF -DBUILD_STATIC=ON \
         -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF \
         -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
         -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_Fortran_COMPILER=mpif90 \
         -DHDF5_ROOT=… -DCMAKE_INSTALL_PREFIX=build_pic
make -j16 && make install
```

- 用途：SU2 将 `libROM.a` 链入 Python 包装共享对象（`_pysu2.so`/`_pysu2ad.so`），
  静态库必须 PIC，否则报 `relocation R_X86_64_PC32 … recompile with -fPIC`。
- 已用 `objdump -r` 验证：0 个 `R_X86_64_32/32S` 绝对重定位。
- **SU2 对齐（必须）**：该库须对 SU2 vendor 的 `libsu2hdf5.a`（HDF5 1.12.1）重编——flexi 1.12.0 头文件编出的 libROM.a 在 SU2 内会因 `H5check_version` 头/库不匹配 abort（见 §10）。脚本 Step 8b 与 install_su2.sh 均自动执行。

## 6. 验证记录

| 验证项 | 结果 |
|---|---|
| `ctest`（`build/tests`） | **29/29 通过**（19 串行 + 10 MPI 并行，默认 3 进程），含 StaticSVD/DMD/DEIM/QDEIM/S_OPT/GreedyCustomSampler/NNLS/QR/Matrix/RandomizedSVD/IncrementalSVDBrand/HDFDatabase/interpolation_gradients 等 |
| 共享库冒烟测试 | C++17 程序（BasisGenerator 静态 SVD）链接 `libROM.so`，`mpirun -np 2` 运行通过 |
| PIC 静态库冒烟测试 | 同一程序链接 `libROM.a` + ScaLAPACK/BLAS/LAPACK/HDF5/z/gfortran/`-lmpi_mpifh`，运行通过 |
| PIC 检查 | `libROM.a` 与 `libmetis.a` 均无绝对重定位；`libHYPRE.a` 以 `-fPIC` 编译 |
| 端到端 | `bash install_librom.sh` 完整跑通（首次运行发现并修复 HDF5 库目录 bug，见 §8.1） |
| SU2 对齐（Step 8b） | 检测到 SU2 构建树后自动重编 libROM.a 对 vendor HDF5 1.12.1；PIC 复验通过 |
| SU2 端到端（2026-10-07） | SU2 全新安装 + SAVE_LIBROM=YES 算例矩阵全过，ROM 开/关输出逐位一致（见 §10） |

## 7. 使用指南

```bash
source /home/tang/packages/libROM/librom_env.sh
```

| 变量 | 用途 |
|---|---|
| `LIBROM_CFLAGS` | `-I…/build/include`（含 `librom.h` 等） |
| `LIBROM_LDFLAGS` | 链接**全功能共享库**（含 MFEM 接口），自带 rpath |
| `LIBROM_STATIC_LIB_DIR` / `LIBROM_STATIC_INCLUDE_DIR` | PIC 静态核心的库/头文件目录 |
| `LIBROM_STATIC_LDFLAGS` | 链接 PIC 静态核心的**完整依赖链**（ScaLAPACK、lapack/blas、并行 HDF5、z、dl、m、gfortran、`mpi_mpifh`）；HDF5 段随对齐状态自动切换（`LIBROM_HDF5_NOTE` 注明，见 §10） |
| `LIBROM_MFEM_CFLAGS` | 代码包含 libROM 的 MFEM 头文件（如 `mfem/PointwiseSnapshot.hpp`）时追加 |
| `MFEM_DIR` / `HYPRE_DIR` / `SCALAPACK_DIR` | 依赖位置 |

链接示例：

```bash
# 全功能共享库
mpicxx -std=c++17 solver.cpp ${LIBROM_CFLAGS} ${LIBROM_LDFLAGS} -o solver.out

# PIC 静态核心（如 SU2 内部）
mpicxx -std=c++17 solver.cpp -I${LIBROM_STATIC_INCLUDE_DIR} ${LIBROM_STATIC_LDFLAGS} -o solver.out
```

常用头文件：`librom.h`、`linalg/BasisGenerator.h`、`linalg/Matrix.h`、`linalg/Vector.h`、
`algo/DMD.h`、`hyperreduction/DEIM.h`、`hyperreduction/GNAT.h`。

## 8. 重要注意事项（踩坑记录）

1. **flexi HDF5 的库不在构建树内**：头文件/`h5cc` 在 `…/HDF5/build/src/HDF5-build`，
   但库文件在 `…/HDF5/build/lib`（高出两级）。`-L` 与 rpath 必须指向后者。
   `install_librom.sh` 已实现自动探测（兼容标准安装与 flexi 两种布局）。
2. **C++17 强制**：上游 #320 起使用 `cxx_std_17`。SU2 等下游项目需同步加 `-std=c++17`。
3. **PIC 全链路**：凡是要链入共享对象的静态库都必须 PIC——ScaLAPACK（SLmake.inc）、
   HYPRE（CFLAGS）、metis（CFLAGS）、libROM 静态构建（`CMAKE_POSITION_INDEPENDENT_CODE=ON`）。
4. **系统 parmetis 干扰**：系统装有 `libparmetis-dev`（`/lib/libparmetis.so`，同为 4.0.3）。
   libROM CMake 必须显式 `-DPARMETIS_DIR=dependencies/parmetis-4.0.3/build/lib`，
   否则 `PARMETIS_DIR` 为空导致 hint 变成 `/lib` 而命中系统库。
   修改 CMake 缓存变量后需 `cmake -UPARMETIS -UPARMETIS_INCLUDES .` 清缓存才生效。
5. **`dependencies/hypre` 目录陷阱**：上游 `scripts/setup.sh` 以“目录是否存在”判断是否
   安装 HYPRE，但 git 仓库里该目录自带 `.gitignore` 恒存在 → HYPRE 被静默跳过 →
   MFEM 链接失败。本机现由 `install_librom.sh` 按产物文件（`libHYPRE.a`）判断，无此问题。
6. **静态链接需 `-lmpi_mpifh`**：libROM 含 Fortran 源码（`scalapack_f_wrapper.f90`），
   以 `mpicxx` 链接静态库时其 Fortran 版 MPI 符号（`mpi_comm_rank_` 等）需显式补
   OpenMPI 的 Fortran 绑定库；已写入 `LIBROM_STATIC_LDFLAGS`。
7. **`BasisGenerator` 生命周期**：析构会释放 MPI 通信子，必须在 `MPI_Finalize()` 之前
   析构（放作用域块内），否则 OpenMPI 报 `MPI_Comm_free() after MPI_FINALIZE` 并中止。
8. **并行 HDF5 是硬要求**：新版无条件编译 `utils/HDFDatabaseMPIO.cpp`
   （调用 `H5Pset_fapl_mpio`），串行 HDF5 无法通过编译。flexi HDF5 已确认
   `H5_HAVE_PARALLEL=1`。
9. **toolchain 文件勿用**：`scripts/compile.sh` 默认带的 toolchain 面向 LLNL TOSS4
   （MKL），本机须直接传编译器变量。
10. **BLAS 实现为 OpenBLAS**：CMake 自动发现系统 OpenBLAS（优于参考实现），
    ScaLAPACK 与之兼容；勿改 `SLmake.inc` 后混用不同 BLAS。
11. **SU2 要求 HDF5 版本对齐**：build_pic 必须对 SU2 vendor 的 `libsu2hdf5.a`（1.12.1）编译，flexi HDF5（1.12.0）编出的 libROM.a 会让 SU2_CFD 在 SAVE_LIBROM=YES 首个样本 abort（`H5check_version` 不匹配）。详见 §10；脚本 Step 8b 与 install_su2.sh 均已自动处理。

## 9. 常用维护操作

```bash
# 完整重建（依赖已建则自动跳过，仅重建 libROM 双构建，约 5–10 分钟）
bash /home/tang/packages/libROM/install_librom.sh

# 只重跑单元测试
cd /home/tang/packages/libROM/build/tests && ctest

# 强制重建某一依赖：删除对应产物后重跑安装脚本，例如
rm -rf /home/tang/packages/libROM/dependencies/hypre/src/hypre   # 重建 HYPRE
rm -rf /home/tang/packages/libROM/dependencies/mfem_parallel/libmfem.so*  # 重建 MFEM
rm -rf /home/tang/packages/libROM/dependencies/parmetis-4.0.3/build       # 重建 ParMETIS

# 查看共享库运行时依赖解析
ldd /home/tang/packages/libROM/build/lib/libROM.so
```

> 注：`dependencies/` 整体被仓库根 `.gitignore` 忽略；`build/`、`build_pic/`、
> 注：`dependencies/`、`build/`、`build_pic/`、`librom_env.sh` 被忽略或运行时生成；`install_librom.sh` 与本报告已入库（commit 2f7dd3a）。

## 10. SU2 HDF5 版本对齐（2026-10-07 补记，必读）

> 依据 SU2 侧安装要求（SU2 仓库 `nemo_validation/local_tasks.md` 环境维护记录，
> 2026-10-07 深化验证）；实施为 `install_su2.sh` 的 "libROM HDF5 对齐" 步骤与本
> 脚本 Step 8b。

**要求**：`build_pic/lib/libROM.a`（SU2 专用 PIC 静态核心）必须与 SU2 的 CGNS
使用**同一份 HDF5**——SU2 在树内 vendor 编译静态 `libsu2hdf5.a`（HDF5 **1.12.1**，
MPI 版，`H5_HAVE_PARALLEL=1`）。libROM 的 H5 符号在 SU2 二进制内会解析到这份静态
代码；HDF5 的 `H5check_version()` 对**任何方向**的头/库版本不匹配都会 `abort()`。

**症状**：用 flexi HDF5（1.12.0）编出的 libROM.a 链入 SU2 后，`SAVE_LIBROM=YES`
的**首个采样点**即 SIGABRT，stderr 打印：

```text
The HDF5 header files used to compile this application do not match
the version used by the HDF5 library to which this application is linked.
Headers are 1.12.0, library is 1.12.1
```

注意两点迷惑性：①两个方向的错配都会炸（vendor 1.12.1 / flexi 1.12.0，反之亦然）；
②两者 SONAME 同为 `libhdf5.so.200`。另外，在 SU2 链接行显式加 `-L…flexi… -lhdf5`
也无效——libsu2hdf5.a 的符号定义在链接序中优先生效，libROM 的调用仍绑定到它。

**处置**（两个入口等价，均自动执行）：
1. `install_su2.sh`（推荐）：meson setup 之后先 `ninja externals/cgns/hdf5/libsu2hdf5.a`
   构建 vendor HDF5，再调用配方脚本
   `nemo_validation/verification/scripts/deps_rebuild_librom_vendored_hdf5.sh`
   对 vendor 头 + 静态库重编 libROM PIC（含 PIC 复验），随后全量编译。
   2026-10-07 已以 `rm -rf build` 全新安装实测通过。
2. `install_librom.sh` Step 8b：检测到 SU2 构建树（libsu2hdf5.a 存在）时自动调用
   同一配方脚本提前对齐；全新机器上跳过并告警（SU2 构建阶段会对齐）。
   手动命令：`bash $SU2_HOME/nemo_validation/verification/scripts/deps_rebuild_librom_vendored_hdf5.sh`。

**对齐后的状态**：SU2 二进制内只存在一份静态 HDF5（1.12.1），`ldd bin/SU2_CFD`
无任何 HDF5 运行期依赖；`librom_env.sh` 的 `LIBROM_STATIC_LDFLAGS` 的 HDF5 段
自动切换为 `-L${SU2_HOME}/build/externals/cgns/hdf5 -lsu2hdf5`（`LIBROM_HDF5_NOTE`
注明状态）。

**对齐后验证**（2026-10-07，SU2 侧实测）：thermalbath（NEMO 化学浴）+STATIC_POD
串行（11 维基）、INCREMENTAL_POD（3 维）、np2 并行（逐 rank 产物）、QuickStart
定常收敛分支全部通过；ROM off/static/incr 三种形态 496 行迭代屏幕输出 md5 逐位
一致（对数值零干扰）；it200 与 SU2 串行回归登记值逐位一致。

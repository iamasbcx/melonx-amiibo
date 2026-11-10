using System.Runtime.CompilerServices;

// 回归项目使用真实 ARM64 编译器与缓存协调器，不执行 Windows 无法映射的 iOS JIT 内存。
[assembly: InternalsVisibleTo("CoreOptimization.Tests")]

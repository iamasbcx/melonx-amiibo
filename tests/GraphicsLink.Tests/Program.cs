using System.Reflection;
using System.Runtime.CompilerServices;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;

// 执行实际 ShaderCollection.CheckProgramLink，反射只构造完成/失败状态，避免测试依赖 Vulkan 设备。
// 这些对象没有创建 shader module、pipeline 或驱动资源，因此不能调用它们的设备 Dispose 路径。
Assembly assembly = typeof(VulkanRenderer).Assembly;
Type collectionType = assembly.GetType("Ryujinx.Graphics.Vulkan.ShaderCollection", throwOnError: true)!;
Type shaderType = assembly.GetType("Ryujinx.Graphics.Vulkan.Shader", throwOnError: true)!;
MethodInfo check = collectionType.GetMethod("CheckProgramLink")!;
PropertyInfo linkStatus = collectionType.GetProperty("LinkStatus")!;

void Set(object instance, string field, object value) =>
    instance.GetType().GetField(field, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)!.SetValue(instance, value);

object Create(ProgramLinkStatus shaderStatus, Task pipelineTask)
{
    object shader = RuntimeHelpers.GetUninitializedObject(shaderType);
    Set(shader, "_compileStatus", (int)shaderStatus);
    Set(shader, "CompileTask", Task.CompletedTask);
    Array shaders = Array.CreateInstance(shaderType, 1);
    shaders.SetValue(shader, 0);
    object collection = RuntimeHelpers.GetUninitializedObject(collectionType);
    Set(collection, "_shaders", shaders);
    Set(collection, "_compileTask", pipelineTask);
    Set(collection, "_linkStatus", (int)ProgramLinkStatus.Incomplete);
    return collection;
}

void Verify(object collection, ProgramLinkStatus expected, string description)
{
    object? result = check.Invoke(collection, [false]);
    if (!Equals(result, expected)) throw new InvalidOperationException(description);
    if (expected != ProgramLinkStatus.Incomplete && !Equals(linkStatus.GetValue(collection), expected))
        throw new InvalidOperationException("Terminal link status was not published: " + description);
}

Verify(Create(ProgramLinkStatus.Failure, Task.CompletedTask), ProgramLinkStatus.Failure, "Already failed stage must not become success");
Task failedTask = Task.FromException(new InvalidOperationException("Expected pipeline failure"));
Verify(Create(ProgramLinkStatus.Success, failedTask), ProgramLinkStatus.Failure, "Completed faulted pipeline must not become success");
_ = failedTask.Exception;
Verify(Create(ProgramLinkStatus.Success, Task.FromCanceled(new CancellationToken(true))), ProgramLinkStatus.Failure, "Cancelled pipeline is failure");
Verify(Create(ProgramLinkStatus.Success, Task.CompletedTask), ProgramLinkStatus.Success, "Completed default pipeline publishes success");
TaskCompletionSource pending = new();
object waiting = Create(ProgramLinkStatus.Success, pending.Task);
Verify(waiting, ProgramLinkStatus.Incomplete, "Pending pipeline stays incomplete");
Set(waiting, "_linkStatus", (int)ProgramLinkStatus.Failure);
pending.SetResult();
Verify(waiting, ProgramLinkStatus.Failure, "Failure published before task completion remains failure");
Verify(Create(ProgramLinkStatus.Incomplete, Task.CompletedTask), ProgramLinkStatus.Incomplete, "Incomplete stage stays incomplete");
Console.WriteLine("GraphicsLink: production default pipeline completion, prior stage failure, task failure, cancellation and publication passed.");

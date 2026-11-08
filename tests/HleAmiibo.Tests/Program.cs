using Ryujinx.Common.Configuration;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Services.Nfc.Nfp;
using System;
using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

// 使用实际 HLE 程序集，仅替代需要启动整机模拟的内核事件；不复制被测实现。
const BindingFlags Flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;
const string Id = "0100000000010002";
Assembly assembly = typeof(Horizon).Assembly;
Type deviceType = assembly.GetType("Ryujinx.HLE.HOS.Services.Nfc.Nfp.NfpManager.NfpDevice", true);
Type stateType = assembly.GetType("Ryujinx.HLE.HOS.Services.Nfc.Nfp.NfpManager.NfpDeviceState", true);
Type eventType = assembly.GetType("Ryujinx.HLE.HOS.Kernel.Threading.KEvent", true);
string scratch = Path.Combine(Path.GetTempPath(), "MeloNX-HLE-checks-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(scratch);
AppDataManager.Initialize(scratch);
int checks = 0;

void Check(bool value, string label)
{
    if (!value) throw new InvalidOperationException(label);
    checks++;
    Console.WriteLine("PASS " + label);
}

void Set(object obj, string field, object value) => obj.GetType().GetField(field, Flags).SetValue(obj, value);
object Call(Horizon horizon, string method, params object[] args) => typeof(Horizon).GetMethod(method, Flags).Invoke(horizon, args);

(Horizon Horizon, object Device) Create()
{
    Horizon horizon = (Horizon)RuntimeHelpers.GetUninitializedObject(typeof(Horizon));
    Set(horizon, "<NfpSync>k__BackingField", new object());
    Set(horizon, "<NfpDetectionSignal>k__BackingField", new AutoResetEvent(false));
    Set(horizon, "_nfpLifecycleSync", new object());
    object device = Activator.CreateInstance(deviceType, true);
    Set(device, "State", Enum.Parse(stateType, "SearchingForTag"));
    IList devices = (IList)Activator.CreateInstance(typeof(System.Collections.Generic.List<>).MakeGenericType(deviceType));
    devices.Add(device);
    Set(horizon, "<NfpDevices>k__BackingField", devices);
    return (horizon, device);
}

void AddEvents(object device)
{
    Set(device, "ActivateEvent", RuntimeHelpers.GetUninitializedObject(eventType));
    Set(device, "DeactivateEvent", RuntimeHelpers.GetUninitializedObject(eventType));
}

var first = Create();
Check(first.Horizon.GetVirtualAmiiboStatus().IsSearching, "searching status");
Check(first.Horizon.TryScanVirtualAmiibo(0, "../invalid") == VirtualAmiiboScanResult.InvalidId, "reject invalid ID");
Check(first.Horizon.TryScanVirtualAmiibo(1, Id) == VirtualAmiiboScanResult.StaleDetection, "reject stale epoch");
Check(first.Horizon.TryScanVirtualAmiibo(0, Id) == VirtualAmiiboScanResult.EventsNotReady, "reject absent events before publishing tag");
Check(first.Horizon.GetVirtualAmiiboStatus().IsSearching, "failed submit retains searching state");
AddEvents(first.Device);
var submits = Enumerable.Range(0, 32).Select(_ => Task.Run(() => first.Horizon.TryScanVirtualAmiibo(0, Id))).ToArray();
Task.WaitAll(submits);
Check(submits.Count(t => t.Result == VirtualAmiiboScanResult.Accepted) == 1, "parallel submit accepts exactly once");
Check((string)deviceType.GetField("AmiiboId", Flags).GetValue(first.Device) == Id, "published tag contains submitted ID");
string file = Path.Combine(AppDataManager.BaseDirPath, "system", "amiibo", Id + ".json");
JsonObject saved = JsonNode.Parse(File.ReadAllText(file)).AsObject();
byte[] uuid = Convert.FromBase64String(saved["TagUuid"].GetValue<string>());
Check(uuid.Length == 9 && uuid[3] == (byte)(0x88 ^ uuid[0] ^ uuid[1] ^ uuid[2]) && uuid[8] == (byte)(uuid[4] ^ uuid[5] ^ uuid[6] ^ uuid[7]), "UUID BCC values");
first.Horizon.CloseVirtualAmiiboSession();
first.Horizon.CloseVirtualAmiiboSession();
Check(first.Horizon.TryScanVirtualAmiibo(0, Id) == VirtualAmiiboScanResult.Unavailable, "closed session rejects submission");

var second = Create();
AddEvents(second.Device);
Check(second.Horizon.TryScanVirtualAmiibo(0, Id) == VirtualAmiiboScanResult.Accepted, "next session accepts same virtual card");
Check(Convert.FromBase64String(JsonNode.Parse(File.ReadAllText(file))["TagUuid"].GetValue<string>()).SequenceEqual(uuid), "UUID persists across sessions");
second.Horizon.CloseVirtualAmiiboSession();
string original = File.ReadAllText(file);
File.WriteAllText(file, "{invalid");
var bad = Create();
AddEvents(bad.Device);
Check(bad.Horizon.TryScanVirtualAmiibo(0, Id) == VirtualAmiiboScanResult.StorageError, "malformed JSON reports storage error");
Check(bad.Horizon.GetVirtualAmiiboStatus().IsSearching && File.ReadAllText(file) == "{invalid", "malformed JSON does not publish tag or overwrite file");
bad.Horizon.CloseVirtualAmiiboSession();
File.WriteAllText(file, original);

var worker = Create();
Task lifecycle = Task.Run(() =>
{
    for (int i = 0; i < 100; i++)
    {
        Call(worker.Horizon, "StartNfpDetection", 0u);
        Call(worker.Horizon, "StartNfpDetection", 0u);
        Call(worker.Horizon, "StopNfpDetection", 0u);
    }
    worker.Horizon.CloseVirtualAmiiboSession();
});
Check(lifecycle.Wait(TimeSpan.FromSeconds(10)), "100 repeated worker replace/stop cycles complete");
Check(worker.Horizon.GetVirtualAmiiboStatus().Status == VirtualAmiiboDetectionStatus.Unavailable, "worker close reports unavailable");
Console.WriteLine($"Completed {checks} real HLE checks; scratch data: {scratch}");

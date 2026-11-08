using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Common.Utilities;
using Ryujinx.Cpu;
using Ryujinx.HLE.HOS.Services.Mii;
using Ryujinx.HLE.HOS.Services.Mii.Types;
using Ryujinx.HLE.HOS.Services.Nfc.AmiiboDecryption;
using Ryujinx.HLE.HOS.Services.Nfc.Nfp.NfpManager;
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;

namespace Ryujinx.HLE.HOS.Services.Nfc.Nfp
{
    static class VirtualAmiibo
    {
        private static readonly object Sync = new();

        public static uint OpenedApplicationAreaId;
        public static byte[] ApplicationBytes = [];
        public static string InputBin = string.Empty;
        public static string NickName = string.Empty;
        private static readonly AmiiboJsonSerializerContext _serializerContext = AmiiboJsonSerializerContext.Default;

        /// <summary>
        /// 清理一次扫描会话的临时状态。虚拟 JSON 文件属于持久数据，不在此处删除。
        /// </summary>
        public static void ResetSession()
        {
            lock (Sync)
            {
                OpenedApplicationAreaId = 0;
                ApplicationBytes = [];
                InputBin = string.Empty;
                NickName = string.Empty;
            }
        }

        /// <summary>
        /// 预创建并校验虚拟 amiibo 的持久记录，提交状态前调用。
        /// </summary>
        public static void PrepareVirtualSession(string amiiboId)
        {
            lock (Sync)
            {
                if (string.IsNullOrWhiteSpace(amiiboId) || amiiboId.Length != 16 || amiiboId.Any(c => !Uri.IsHexDigit(c)))
                {
                    throw new ArgumentException("Invalid virtual amiibo ID.", nameof(amiiboId));
                }

                InputBin = string.Empty;
                ApplicationBytes = [];
                OpenedApplicationAreaId = 0;
                NickName = string.Empty;
                VirtualAmiiboFile file = LoadAmiiboFile(amiiboId.ToUpperInvariant());
                ValidateVirtualFile(file, amiiboId);
                if (file.TagUuid == null || file.TagUuid.Length == 0)
                {
                    file.TagUuid = GenerateRandomUuid();
                    SaveAmiiboFile(file);
                }
            }
        }

        public static byte[] GenerateUuid(string amiiboId, bool useRandomUuid)
        {
            lock (Sync)
            {
                if (useRandomUuid)
                {
                    return GenerateRandomUuid();
                }

                VirtualAmiiboFile virtualAmiiboFile = LoadAmiiboFile(amiiboId);

                if (virtualAmiiboFile.TagUuid.Length == 0)
                {
                    virtualAmiiboFile.TagUuid = GenerateRandomUuid();

                    SaveAmiiboFile(virtualAmiiboFile);
                }

                return virtualAmiiboFile.TagUuid;
            }
        }

        private static byte[] GenerateRandomUuid()
        {
            lock (Sync)
            {
                byte[] uuid = new byte[9];

                RandomNumberGenerator.Fill(uuid);

                uuid[3] = (byte)(0x88 ^ uuid[0] ^ uuid[1] ^ uuid[2]);
                // BCC1 校验 UID 的第 4 到第 7 个字节；索引 3 保留给 BCC0。
                uuid[8] = (byte)(uuid[4] ^ uuid[5] ^ uuid[6] ^ uuid[7]);

                return uuid;
            }
        }

        public static CommonInfo GetCommonInfo(string amiiboId)
        {
            lock (Sync)
            {
                VirtualAmiiboFile amiiboFile = LoadAmiiboFile(amiiboId);

                return new CommonInfo()
                {
                    LastWriteYear = (ushort)amiiboFile.LastWriteDate.Year,
                    LastWriteMonth = (byte)amiiboFile.LastWriteDate.Month,
                    LastWriteDay = (byte)amiiboFile.LastWriteDate.Day,
                    WriteCounter = amiiboFile.WriteCounter,
                    Version = 1,
                    ApplicationAreaSize = AmiiboConstants.ApplicationAreaSize,
                    Reserved = new Array52<byte>(),
                };
            }
        }

        public static RegisterInfo GetRegisterInfo(ITickSource tickSource, string amiiboId, string userName)
        {
            lock (Sync)
            {
                VirtualAmiiboFile amiiboFile = LoadAmiiboFile(amiiboId);
                string nickname = amiiboFile.NickName ?? "Ryujinx";
                if (NickName != string.Empty)
                {
                    nickname = NickName;
                    NickName = string.Empty;
                }

                UtilityImpl utilityImpl = new(tickSource);
                CharInfo charInfo = new();

                charInfo.SetFromStoreData(StoreData.BuildDefault(utilityImpl, 0));

                // This is the player's name
                charInfo.Nickname = Nickname.FromString(userName);

                RegisterInfo registerInfo = new()
                {
                    MiiCharInfo = charInfo,
                    FirstWriteYear = (ushort)amiiboFile.FirstWriteDate.Year,
                    FirstWriteMonth = (byte)amiiboFile.FirstWriteDate.Month,
                    FirstWriteDay = (byte)amiiboFile.FirstWriteDate.Day,
                    FontRegion = 0,
                    Reserved1 = new Array64<byte>(),
                    Reserved2 = new Array58<byte>(),
                };
                // This is the amiibo's name
                byte[] nicknameBytes = System.Text.Encoding.UTF8.GetBytes(nickname);
                nicknameBytes.CopyTo(registerInfo.Nickname.AsSpan());

                return registerInfo;
            }
        }

        public static void UpdateNickName(string amiiboId, string newNickName)
        {
            lock (Sync)
            {
                VirtualAmiiboFile virtualAmiiboFile = LoadAmiiboFile(amiiboId);
                virtualAmiiboFile.NickName = newNickName;
                if (InputBin != string.Empty)
                {
                    AmiiboBinReader.SaveBinFile(InputBin, virtualAmiiboFile.NickName);
                    return;
                }

                SaveAmiiboFile(virtualAmiiboFile);
            }
        }

        public static bool OpenApplicationArea(string amiiboId, uint applicationAreaId)
        {
            lock (Sync)
            {
                VirtualAmiiboFile virtualAmiiboFile = LoadAmiiboFile(amiiboId);
                if (ApplicationBytes.Length > 0)
                {
                    OpenedApplicationAreaId = applicationAreaId;
                    return true;
                }

                if (virtualAmiiboFile.ApplicationAreas.Any(item => item.ApplicationAreaId == applicationAreaId))
                {
                    OpenedApplicationAreaId = applicationAreaId;

                    return true;
                }

                return false;
            }
        }

        public static byte[] GetApplicationArea(string amiiboId)
        {
            lock (Sync)
            {
                if (ApplicationBytes.Length > 0)
                {
                    byte[] bytes = ApplicationBytes;
                    ApplicationBytes = [];
                    return bytes;
                }

                VirtualAmiiboFile virtualAmiiboFile = LoadAmiiboFile(amiiboId);

                foreach (VirtualAmiiboApplicationArea applicationArea in virtualAmiiboFile.ApplicationAreas)
                {
                    if (applicationArea.ApplicationAreaId == OpenedApplicationAreaId)
                    {
                        return applicationArea.ApplicationArea;
                    }
                }

                return [];
            }
        }

        public static bool CreateApplicationArea(string amiiboId, uint applicationAreaId, byte[] applicationAreaData)
        {
            lock (Sync)
            {
                VirtualAmiiboFile virtualAmiiboFile = LoadAmiiboFile(amiiboId);

                if (virtualAmiiboFile.ApplicationAreas.Any(item => item.ApplicationAreaId == applicationAreaId))
                {
                    return false;
                }

                virtualAmiiboFile.ApplicationAreas.Add(new VirtualAmiiboApplicationArea()
                {
                    ApplicationAreaId = applicationAreaId,
                    ApplicationArea = applicationAreaData,
                });

                SaveAmiiboFile(virtualAmiiboFile);

                return true;
            }
        }

        public static void SetApplicationArea(string amiiboId, byte[] applicationAreaData)
        {
            lock (Sync)
            {
                if (InputBin != string.Empty)
                {
                    AmiiboBinReader.SaveBinFile(InputBin, applicationAreaData);
                    return;
                }

                VirtualAmiiboFile virtualAmiiboFile = LoadAmiiboFile(amiiboId);

                if (virtualAmiiboFile.ApplicationAreas.Any(item => item.ApplicationAreaId == OpenedApplicationAreaId))
                {
                    for (int i = 0; i < virtualAmiiboFile.ApplicationAreas.Count; i++)
                    {
                        if (virtualAmiiboFile.ApplicationAreas[i].ApplicationAreaId == OpenedApplicationAreaId)
                        {
                            virtualAmiiboFile.ApplicationAreas[i] = new VirtualAmiiboApplicationArea()
                            {
                                ApplicationAreaId = OpenedApplicationAreaId,
                                ApplicationArea = applicationAreaData,
                            };

                            break;
                        }
                    }

                    SaveAmiiboFile(virtualAmiiboFile);
                }
            }
        }

        private static VirtualAmiiboFile LoadAmiiboFile(string amiiboId)
        {
            lock (Sync)
            {
                Directory.CreateDirectory(Path.Join(AppDataManager.BaseDirPath, "system", "amiibo"));

                string filePath = Path.Join(AppDataManager.BaseDirPath, "system", "amiibo", $"{amiiboId}.json");

                VirtualAmiiboFile virtualAmiiboFile;

                if (File.Exists(filePath))
                {
                    virtualAmiiboFile = JsonHelper.DeserializeFromFile(filePath, _serializerContext.VirtualAmiiboFile);

                }
                else
                {
                    virtualAmiiboFile = new VirtualAmiiboFile()
                    {
                        FileVersion = 0,
                        TagUuid = [],
                        AmiiboId = amiiboId,
                        FirstWriteDate = DateTime.Now,
                        LastWriteDate = DateTime.Now,
                        WriteCounter = 0,
                        ApplicationAreas = [],
                    };

                    SaveAmiiboFile(virtualAmiiboFile);
                }

                return virtualAmiiboFile;
            }
        }

        public static void SaveAmiiboFile(VirtualAmiiboFile virtualAmiiboFile)
        {
            lock (Sync)
            {
                string filePath = Path.Join(AppDataManager.BaseDirPath, "system", "amiibo", $"{virtualAmiiboFile.AmiiboId}.json");
                Directory.CreateDirectory(Path.GetDirectoryName(filePath));
                string temporaryPath = filePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    JsonHelper.SerializeToFile(temporaryPath, virtualAmiiboFile, _serializerContext.VirtualAmiiboFile);
                    // 同目录替换避免进程退出或写入失败留下被截断的持久记录。
                    File.Move(temporaryPath, filePath, true);
                }
                finally
                {
                    if (File.Exists(temporaryPath))
                    {
                        File.Delete(temporaryPath);
                    }
                }
            }
        }

        private static void ValidateVirtualFile(VirtualAmiiboFile file, string expectedId)
        {
            if (file.FileVersion != 0 || !string.Equals(file.AmiiboId, expectedId, StringComparison.OrdinalIgnoreCase) ||
                file.TagUuid == null || file.ApplicationAreas == null)
            {
                throw new InvalidDataException("Virtual amiibo record version or ID mismatch.");
            }

            if (file.TagUuid.Length != 0 && (file.TagUuid.Length != 9 ||
                file.TagUuid[3] != (byte)(0x88 ^ file.TagUuid[0] ^ file.TagUuid[1] ^ file.TagUuid[2]) ||
                file.TagUuid[8] != (byte)(file.TagUuid[4] ^ file.TagUuid[5] ^ file.TagUuid[6] ^ file.TagUuid[7])))
            {
                throw new InvalidDataException("Invalid virtual amiibo UUID.");
            }

            if (file.ApplicationAreas.Any(area => area.ApplicationArea == null || area.ApplicationArea.Length != AmiiboConstants.ApplicationAreaSize) ||
                file.ApplicationAreas.Select(area => area.ApplicationAreaId).Distinct().Count() != file.ApplicationAreas.Count)
            {
                throw new InvalidDataException("Invalid virtual amiibo application areas.");
            }

            if (file.FirstWriteDate == default || file.LastWriteDate == default)
            {
                throw new InvalidDataException("Invalid virtual amiibo write date.");
            }

            if (file.NickName != null && System.Text.Encoding.UTF8.GetByteCount(file.NickName) > 40)
            {
                throw new InvalidDataException("Invalid virtual amiibo nickname.");
            }
        }

        public static bool SaveFileExists(VirtualAmiiboFile virtualAmiiboFile)
        {
            lock (Sync)
            {
                if (InputBin != string.Empty)
                {
                    SaveAmiiboFile(virtualAmiiboFile);
                    return true;

                }

                return File.Exists(Path.Join(AppDataManager.BaseDirPath, "system", "amiibo", $"{virtualAmiiboFile.AmiiboId}.json"));
            }
        }
    }
}

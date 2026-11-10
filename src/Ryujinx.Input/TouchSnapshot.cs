using System.Numerics;

namespace Ryujinx.Input
{
    /// <summary>宿主触点的按值快照；Id 在按下至抬起期间保持不变，Position 使用游戏视图坐标。</summary>
    public readonly record struct TouchSnapshot(int Id, Vector2 Position);
}

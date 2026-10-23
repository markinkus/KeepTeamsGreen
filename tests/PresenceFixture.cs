// Minimal UIA provider double. Tests compile the REAL reader against this API;
// this checks traversal/cache logic, not Windows/Teams provider compatibility.
namespace KtgPresenceFixture {
    using System;
    using System.Collections.Generic;
    public struct Rect {
        public bool IsEmpty;
        public double Left, Top, Width, Height;
        public double Right { get { return Left + Width; } }
        public double Bottom { get { return Top + Height; } }
    }
    public enum TreeScope { Element }
    public sealed class CacheRequest {
        public TreeScope TreeScope;
        public void Add(object property) { }
    }
    public sealed class ElementNotAvailableException : Exception { }
    public sealed class ControlType {
        public static readonly ControlType Button = new ControlType();
        public static readonly ControlType Image = new ControlType();
        public static readonly ControlType ListItem = new ControlType();
        public static readonly ControlType TreeItem = new ControlType();
        public static readonly ControlType Text = new ControlType();
        public static readonly ControlType Tree = new ControlType();
        public static readonly ControlType List = new ControlType();
        public static readonly ControlType Group = new ControlType();
        public static readonly ControlType Custom = new ControlType();
    }
    public sealed class AutomationElement {
        public sealed class AutomationElementInformation {
            public string Name = "", AutomationId = "", HelpText = "";
            public bool IsOffscreen;
            public ControlType ControlType = ControlType.Button;
            public Rect BoundingRectangle = new Rect { Left = 900, Top = 40, Width = 50, Height = 30 };
        }
        public static readonly object NameProperty = new object(), AutomationIdProperty = new object(),
            HelpTextProperty = new object(), IsOffscreenProperty = new object(), ControlTypeProperty = new object(),
            BoundingRectangleProperty = new object();
        public static readonly Dictionary<IntPtr, AutomationElement> Windows = new Dictionary<IntPtr, AutomationElement>();
        private readonly AutomationElementInformation information = new AutomationElementInformation();
        public AutomationElementInformation Cached {
            get { if (Unavailable) throw new ElementNotAvailableException(); return information; }
        }
        public AutomationElement Parent;
        public readonly List<AutomationElement> Children = new List<AutomationElement>();
        public bool Unavailable;
        public int Refreshes;
        public int ChildReads;
        public int ChangeOnRefresh;
        public string ChangedName;
        public AutomationElement(string name, string id) { Cached.Name = name; Cached.AutomationId = id; }
        public void Add(AutomationElement child) { child.Parent = this; Children.Add(child); }
        public static AutomationElement FromHandle(IntPtr handle) { return Windows[handle]; }
        public AutomationElement GetUpdatedCache(CacheRequest request) {
            if (Unavailable) throw new ElementNotAvailableException();
            Refreshes++;
            if (ChangeOnRefresh == Refreshes) information.Name = ChangedName;
            return this;
        }
    }
    public sealed class TreeWalker {
        public static readonly TreeWalker ControlViewWalker = new TreeWalker();
        public AutomationElement GetFirstChild(AutomationElement element, CacheRequest request) {
            element.ChildReads++;
            if (element.Unavailable) throw new ElementNotAvailableException();
            return element.Children.Count == 0 ? null : element.Children[0];
        }
        public AutomationElement GetNextSibling(AutomationElement element, CacheRequest request) {
            if (element.Parent == null) return null;
            var siblings = element.Parent.Children;
            int index = siblings.IndexOf(element) + 1;
            return index < siblings.Count ? siblings[index] : null;
        }
    }

    // Fake only the OS boundary. The real capture loops, shape classifier,
    // ownership checks and DPI/DC finally blocks still execute in tests.
    public static class Screen {
        public static IntPtr Window = new IntPtr(48);
        public static bool Visible, Minimized, Blocked, CoverDuringRead, DpiAllowed, DcFails, CopyFails;
        public static int CenterX, CenterY, Radius, PixelCalls, DcGets, DcReleases, DpiRestores;
        public static uint Color;
        public static int CaptureX, CaptureY, BitmapDeletes, MemoryDeletes;
        public static void Reset() {
            Visible = true; Minimized = false; Blocked = false; CoverDuringRead = false;
            DpiAllowed = true; DcFails = false; CenterX = 123; CenterY = 173; Radius = 3;
            PixelCalls = DcGets = DcReleases = DpiRestores = 0; Color = 0x30a030;
            CaptureX = CaptureY = BitmapDeletes = MemoryDeletes = 0; CopyFails = false;
        }
        public static IntPtr SetDpi(IntPtr value) {
            if (value == new IntPtr(-4)) return DpiAllowed ? new IntPtr(1) : IntPtr.Zero;
            DpiRestores++; return new IntPtr(-4);
        }
        public static IntPtr Owner(int x, int y) {
            return Blocked || (CoverDuringRead && PixelCalls > 0) ? IntPtr.Zero : Window;
        }
        public static uint Pixel(int x, int y) {
            PixelCalls++;
            return (x - CenterX) * (x - CenterX) + (y - CenterY) * (y - CenterY) <= Radius * Radius ? Color : 0x202020;
        }
    }
}

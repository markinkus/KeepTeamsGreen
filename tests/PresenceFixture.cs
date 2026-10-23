// Minimal UIA provider double. Tests compile the REAL reader against this API;
// this checks traversal/cache logic, not Windows/Teams provider compatibility.
namespace KtgPresenceFixture {
    using System;
    using System.Collections.Generic;
    public struct Rect { public bool IsEmpty; public double Left, Top, Width; }
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
    }
    public sealed class AutomationElement {
        public sealed class Information {
            public string Name = "", AutomationId = "", HelpText = "";
            public bool IsOffscreen;
            public ControlType ControlType = ControlType.Button;
            public Rect BoundingRectangle = new Rect { Left = 900, Top = 40, Width = 50 };
        }
        public static readonly object NameProperty = new object(), AutomationIdProperty = new object(),
            HelpTextProperty = new object(), IsOffscreenProperty = new object(), ControlTypeProperty = new object(),
            BoundingRectangleProperty = new object();
        public static readonly Dictionary<IntPtr, AutomationElement> Windows = new Dictionary<IntPtr, AutomationElement>();
        private readonly Information information = new Information();
        public Information Cached {
            get { if (Unavailable) throw new ElementNotAvailableException(); return information; }
        }
        public AutomationElement Parent;
        public readonly List<AutomationElement> Children = new List<AutomationElement>();
        public bool Unavailable;
        public int Refreshes;
        public AutomationElement(string name, string id) { Cached.Name = name; Cached.AutomationId = id; }
        public void Add(AutomationElement child) { child.Parent = this; Children.Add(child); }
        public static AutomationElement FromHandle(IntPtr handle) { return Windows[handle]; }
        public AutomationElement GetUpdatedCache(CacheRequest request) {
            if (Unavailable) throw new ElementNotAvailableException();
            Refreshes++;
            return this;
        }
    }
    public sealed class TreeWalker {
        public static readonly TreeWalker ControlViewWalker = new TreeWalker();
        public AutomationElement GetFirstChild(AutomationElement element, CacheRequest request) {
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
}

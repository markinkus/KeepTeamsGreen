namespace KeepTeamsGreenMonitoring {
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows.Automation;

public sealed class ContactPresenceReading {
    public string Name { get; set; }
    public string State { get; set; }
    public string Diagnostic { get; set; }
}

public sealed class PresenceProbeResult {
    public string State { get; set; }
    public string Diagnostic { get; set; }
    public ContactPresenceReading[] Contacts { get; set; }
}

public static class TeamsPresenceProbe {
    // Only the personal worker accesses these. Never cache a presence value:
    // refresh the account element's properties on every poll.
    private static AutomationElement ownControl;
    private static IntPtr ownWindow;

    private static CacheRequest Properties() {
        var request = new CacheRequest();
        request.TreeScope = TreeScope.Element;
        request.Add(AutomationElement.NameProperty);
        request.Add(AutomationElement.AutomationIdProperty);
        request.Add(AutomationElement.HelpTextProperty);
        request.Add(AutomationElement.IsOffscreenProperty);
        request.Add(AutomationElement.ControlTypeProperty);
        request.Add(AutomationElement.BoundingRectangleProperty);
        return request;
    }
    private static bool Has(string text, string part) {
        return text.IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string OwnState(string name, string help) {
        // Account accessibility labels often use comma-separated fields.
        foreach (string part in (name + "," + help).Split(new char[] { ',', ';', '|', '\n' })) {
            string state = PresenceText.State(part);
            if (state != "Unknown") return state;
        }
        return "Unknown";
    }

    private static string ChildPresence(AutomationElement element, CacheRequest request) {
        string found = "Unknown";
        var queue = new Queue<Tuple<AutomationElement, int>>();
        queue.Enqueue(Tuple.Create(element, 0));
        int visited = 0;
        while (queue.Count > 0 && visited++ < 32) {
            var item = queue.Dequeue();
            AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(item.Item1, request);
            for (int count = 0; child != null && count < 12; count++) {
                var info = child.Cached;
                // Nested avatar badges qualify, ordinary message/preview text does not.
                if (!info.IsOffscreen && (info.ControlType == ControlType.Image || Has(info.AutomationId ?? "", "presence"))) {
                    string state = PresenceText.State(info.Name);
                    if (state != "Unknown") {
                        if (found != "Unknown" && found != state) return "Unknown";
                        found = state;
                    }
                }
                if (item.Item2 < 2 && queue.Count < 32) queue.Enqueue(Tuple.Create(child, item.Item2 + 1));
                child = TreeWalker.ControlViewWalker.GetNextSibling(child, request);
            }
        }
        return found;
    }

    private static PresenceProbeResult InspectCore(IntPtr windowHandle, string[] names, bool personal) {
        var result = new PresenceProbeResult {
            State = "Unknown", Diagnostic = "Stato personale non esposto da Teams",
            Contacts = new ContactPresenceReading[0]
        };
        var readings = new List<ContactPresenceReading>();
        var evidence = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (string name in names ?? new string[0]) {
            if (!evidence.ContainsKey(name)) evidence.Add(name, new HashSet<string>());
        }
        try {
            CacheRequest request = Properties();
            if (personal && ownWindow == windowHandle && ownControl != null) {
                try {
                    AutomationElement cached = ownControl.GetUpdatedCache(request);
                    var info = cached.Cached;
                    // Revalidate identity too: Teams can replace/reuse accessible nodes.
                    if (!info.IsOffscreen && PresenceText.OwnAccount(info.Name, info.AutomationId, false)) {
                        string state = OwnState(info.Name, info.HelpText);
                        if (state == "Unknown") state = ChildPresence(cached, request);
                        if (state != "Unknown") {
                            result.State = state;
                            result.Diagnostic = "Stato personale aggiornato dal controllo account";
                            return result;
                        }
                    }
                } catch (ElementNotAvailableException) { }
                  catch (InvalidOperationException) { }
                ownControl = null;
            }
            AutomationElement root = AutomationElement.FromHandle(windowHandle).GetUpdatedCache(request);
            System.Windows.Rect bounds = root.Cached.BoundingRectangle;
            var queue = new Queue<Tuple<AutomationElement, int>>();
            queue.Enqueue(Tuple.Create(root, 0));
            Stopwatch budget = Stopwatch.StartNew();
            int visited = 0;
            bool truncated = false;
            int milliseconds = personal ? 1500 : 4000;
            while (queue.Count > 0 && visited++ < 2000 && budget.ElapsedMilliseconds < milliseconds) {
                var item = queue.Dequeue();
                try {
                    AutomationElement node = item.Item1;
                    var info = node.Cached;
                    string name = info.Name ?? "";
                    string id = info.AutomationId ?? "";
                    bool message = Has(id, "message-body") || Has(id, "chat-message") || Has(id, "message-content");
                    if (!info.IsOffscreen && !message) {
                        bool header = !bounds.IsEmpty && !info.BoundingRectangle.IsEmpty &&
                            info.BoundingRectangle.Top < bounds.Top + 180 &&
                            info.BoundingRectangle.Left >= bounds.Left + bounds.Width * 0.5;
                        if (personal && PresenceText.OwnAccount(name, id, header)) {
                            string own = OwnState(name, info.HelpText ?? "");
                            if (own == "Unknown") own = ChildPresence(node, request);
                            if (own != "Unknown") {
                                // An explicit account control is independent of chat-tree completeness.
                                ownControl = node; ownWindow = windowHandle;
                                result.State = own;
                                result.Diagnostic = "Stato personale letto dal controllo account";
                                return result;
                            }
                        } else if (!personal && (info.ControlType == ControlType.Button || info.ControlType == ControlType.Image ||
                                   info.ControlType == ControlType.ListItem || info.ControlType == ControlType.TreeItem)) {
                            foreach (string person in evidence.Keys) {
                                string state = PresenceText.NamedState(name, person);
                                if (state == "Unknown" && PresenceText.IsIdentity(name, person)) state = ChildPresence(node, request);
                                if (state != "Unknown") evidence[person].Add(state);
                            }
                        }
                    }
                    if (!message && item.Item2 < 32) {
                        AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(node, request);
                        int count = 0;
                        for (; child != null && count < 150 && queue.Count < 2000 && budget.ElapsedMilliseconds < milliseconds; count++) {
                            queue.Enqueue(Tuple.Create(child, item.Item2 + 1));
                            child = TreeWalker.ControlViewWalker.GetNextSibling(child, request);
                        }
                        if (child != null) truncated = true;
                    } else if (!message && item.Item2 >= 32) {
                        if (TreeWalker.ControlViewWalker.GetFirstChild(node, request) != null) truncated = true;
                    }
                } catch (ElementNotAvailableException) { truncated = true; }
                  catch (InvalidOperationException) { truncated = true; }
            }
            if (queue.Count > 0 || truncated) {
                result.Diagnostic = "Scansione parziale: interfaccia troppo ampia o lenta";
                // Partial evidence must not become a confirmed state.
                foreach (var states in evidence.Values) states.Clear();
            }
        } catch (Exception exception) {
            result.Diagnostic = "Lettura accessibilita fallita: " + exception.GetType().Name;
            foreach (var states in evidence.Values) states.Clear();
        }
        foreach (var pair in evidence) {
            string state = "Unknown";
            if (pair.Value.Count == 1) foreach (string value in pair.Value) state = value;
            readings.Add(new ContactPresenceReading {
                Name = pair.Key, State = state,
                Diagnostic = pair.Value.Count > 1 ? "Indicatori discordanti o nome omonimo" :
                    (state == "Unknown" ? "Nessun dato accessibile (lista chat/scheda); monitoraggio in background non garantito" : "Indicatore accessibile associato al nome")
            });
        }
        result.Contacts = readings.ToArray();
        return result;
    }

    public static Task<PresenceProbeResult> BeginInspect(IntPtr windowHandle, string[] names) {
        return Task.Factory.StartNew<PresenceProbeResult>(delegate { return InspectCore(windowHandle, names, true); });
    }

    public static Task<PresenceProbeResult> BeginInspectContacts(IntPtr windowHandle, string[] names) {
        return BeginInspectContacts(windowHandle, names, true);
    }

    public static Task<PresenceProbeResult> BeginInspectContacts(IntPtr windowHandle, string[] names, bool visibleBadges) {
        return Task.Factory.StartNew<PresenceProbeResult>(delegate { return ConversationPresenceReader.Inspect(windowHandle, names, visibleBadges); });
    }
}
}

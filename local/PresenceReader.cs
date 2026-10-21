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

    private static string ChildPresence(AutomationElement element) {
        string found = "Unknown";
        AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(element);
        for (int count = 0; child != null && count < 12; count++) {
            AutomationElement.AutomationElementInformation info = child.Current;
            // A chat preview is Text; only explicit indicators qualify.
            if (!info.IsOffscreen && (info.ControlType == ControlType.Image || Has(info.AutomationId ?? "", "presence"))) {
                string state = PresenceText.State(info.Name);
                if (state != "Unknown") {
                    if (found != "Unknown" && found != state) return "Unknown";
                    found = state;
                }
            }
            child = TreeWalker.ControlViewWalker.GetNextSibling(child);
        }
        return found;
    }

    public static PresenceProbeResult Inspect(IntPtr windowHandle, string[] names) {
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
            AutomationElement root = AutomationElement.FromHandle(windowHandle);
            System.Windows.Rect bounds = root.Current.BoundingRectangle;
            var queue = new Queue<Tuple<AutomationElement, int>>();
            queue.Enqueue(Tuple.Create(root, 0));
            var ownStates = new HashSet<string>();
            Stopwatch budget = Stopwatch.StartNew();
            int visited = 0;
            bool truncated = false;
            while (queue.Count > 0 && visited++ < 2000 && budget.ElapsedMilliseconds < 4000) {
                var item = queue.Dequeue();
                try {
                    AutomationElement node = item.Item1;
                    var info = node.Current;
                    string name = info.Name ?? "";
                    string id = info.AutomationId ?? "";
                    bool message = Has(id, "message-body") || Has(id, "chat-message") || Has(id, "message-content");
                    if (!info.IsOffscreen && !message) {
                        bool header = !bounds.IsEmpty && !info.BoundingRectangle.IsEmpty &&
                            info.BoundingRectangle.Top < bounds.Top + 180 &&
                            info.BoundingRectangle.Left >= bounds.Left + bounds.Width * 0.5;
                        if (PresenceText.OwnAccount(name, id, header)) {
                            string own = OwnState(name, info.HelpText ?? "");
                            if (own == "Unknown") own = ChildPresence(node);
                            if (own != "Unknown") ownStates.Add(own);
                        } else if (info.ControlType == ControlType.Button || info.ControlType == ControlType.Image ||
                                   info.ControlType == ControlType.ListItem || info.ControlType == ControlType.TreeItem) {
                            foreach (string person in evidence.Keys) {
                                string state = PresenceText.NamedState(name, person);
                                if (state == "Unknown" && PresenceText.IsIdentity(name, person)) state = ChildPresence(node);
                                if (state != "Unknown") evidence[person].Add(state);
                            }
                        }
                    }
                    if (!message && item.Item2 < 16) {
                        AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(node);
                        int count = 0;
                        for (; child != null && count < 150 && queue.Count < 2000 && budget.ElapsedMilliseconds < 4000; count++) {
                            queue.Enqueue(Tuple.Create(child, item.Item2 + 1));
                            child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                        }
                        if (child != null) truncated = true;
                    } else if (!message && item.Item2 >= 16) {
                        if (TreeWalker.ControlViewWalker.GetFirstChild(node) != null) truncated = true;
                    }
                } catch (ElementNotAvailableException) { truncated = true; }
                  catch (InvalidOperationException) { truncated = true; }
            }
            if (queue.Count > 0 || truncated) {
                result.Diagnostic = "Scansione parziale: interfaccia troppo ampia o lenta";
                // Partial evidence must not become a confirmed state.
                foreach (var states in evidence.Values) states.Clear();
            } else {
                if (ownStates.Count == 1) foreach (string state in ownStates) result.State = state;
                if (result.State != "Unknown") result.Diagnostic = "Stato personale letto dal controllo account";
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
                    (state == "Unknown" ? "Indicatore non esposto: mostra la persona in Teams" : "Indicatore accessibile associato al nome")
            });
        }
        result.Contacts = readings.ToArray();
        return result;
    }

    public static Task<PresenceProbeResult> BeginInspect(IntPtr windowHandle, string[] names) {
        return Task.Factory.StartNew<PresenceProbeResult>(delegate { return Inspect(windowHandle, names); });
    }
}
}

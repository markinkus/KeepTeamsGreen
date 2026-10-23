namespace KeepTeamsGreenMonitoring {
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;

// Contacts are read from COMPLETE conversation rows, not from message bodies
// or a profile card. The personal-account reader is deliberately independent.
public static class ConversationPresenceReader {
    private sealed class RowReading {
        public string Person, State, Source;
    }

    private static bool Has(string value, string part) {
        return (value ?? "").IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static bool Message(string id) {
        return Has(id, "message-body") || Has(id, "chat-message") || Has(id, "message-content") || Has(id, "message-list");
    }

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

    private static bool InColumn(System.Windows.Rect rect, System.Windows.Rect window) {
        // Relative physical bounds: no fixed screen position or 100%-DPI assumption.
        return !rect.IsEmpty && !window.IsEmpty && window.Width > 0 && rect.Width > 0 && rect.Height > 0 &&
            rect.Left >= window.Left && rect.Left < window.Left + window.Width * 0.55 &&
            rect.Right <= window.Left + window.Width * 0.65 && rect.Top >= window.Top && rect.Bottom <= window.Bottom;
    }

    private static bool Row(AutomationElement.AutomationElementInformation info) {
        string id = info.AutomationId ?? "";
        return info.ControlType == ControlType.ListItem || info.ControlType == ControlType.TreeItem ||
            Has(id, "chat-list-item") || Has(id, "chatlist-item") || Has(id, "conversation-item") ||
            Has(id, "chat-item");
    }

    private static bool Group(string id) {
        return Has(id, "group-chat") || Has(id, "groupchat") || Has(id, "channel-item") || Has(id, "meeting-chat");
    }

    private static bool Column(AutomationElement.AutomationElementInformation info) {
        string name = PresenceText.Clean(info.Name).ToLowerInvariant();
        return info.ControlType == ControlType.Tree || info.ControlType == ControlType.List ||
            Has(info.AutomationId, "chat-list") || Has(info.AutomationId, "chatlist") ||
            Has(info.AutomationId, "conversation-list") || Has(info.AutomationId, "chat-pane-list") ||
            name == "chat" || name == "chats" || name == "conversazioni" || name == "chat e canali";
    }

    private static RowReading ReadRow(AutomationElement row, string[] names, CacheRequest request,
        IntPtr window, bool visibleBadges, Stopwatch budget, out bool nestedRows, out bool complete) {
        nestedRows = false;
        complete = true;
        var people = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var states = new HashSet<string>();
        var indicators = new List<Tuple<string, System.Windows.Rect>>();
        var avatars = new List<System.Windows.Rect>();
        var texts = new List<System.Windows.Rect>();
        var avatarNodes = new List<AutomationElement>();
        var textNodes = new List<AutomationElement>();
        var rowInfo = row.Cached;
        var rowRect = rowInfo.BoundingRectangle;
        if (Group(rowInfo.AutomationId)) return null;
        foreach (string person in names) {
            if (PresenceText.ConversationIdentity(rowInfo.Name, person)) people.Add(person);
        }
        var queue = new Queue<Tuple<AutomationElement, int>>();
        queue.Enqueue(Tuple.Create(row, 0));
        int visited = 0;
        while (queue.Count > 0 && visited++ < 128 && budget.ElapsedMilliseconds < 4000) {
            var item = queue.Dequeue();
            var node = item.Item1;
            var info = node.Cached;
            string id = info.AutomationId ?? "";
            if (Message(id)) continue;
            if (Group(id)) { complete = false; break; }
            var nodeRect = info.BoundingRectangle;
            if (item.Item2 > 0 && !nodeRect.IsEmpty && nodeRect.Width > 0 && nodeRect.Height > 0 &&
                (nodeRect.Left < rowRect.Left - 1 || nodeRect.Right > rowRect.Right + 1 ||
                 nodeRect.Top < rowRect.Top - 1 || nodeRect.Bottom > rowRect.Bottom + 1)) {
                // A section/header may own several separate rows. Never mix
                // the name from one row with a badge below/above that row.
                nestedRows = true;
                return null;
            }
            // A nested conversation row belongs to a different person.
            if (item.Item2 > 0 && Row(info)) { nestedRows = true; return null; }
            if (!info.IsOffscreen) {
                foreach (string person in names) {
                    if ((info.ControlType == ControlType.Text || item.Item2 == 0) && PresenceText.IsIdentity(info.Name, person)) {
                        people.Add(person);
                        if (info.ControlType == ControlType.Text) { texts.Add(info.BoundingRectangle); textNodes.Add(node); }
                    }
                }
                bool indicator = info.ControlType == ControlType.Image || Has(id, "presence") || Has(id, "availability") || Has(id, "avatar") || Has(id, "profile-picture");
                if (indicator) {
                    string state = PresenceText.State(info.Name);
                    if (state == "Unknown") state = PresenceText.State(info.HelpText);
                    if (state != "Unknown") indicators.Add(Tuple.Create(state, info.BoundingRectangle));
                    var rect = info.BoundingRectangle;
                    if (!rect.IsEmpty && rect.Width >= 14 && rect.Width <= 96 && rect.Height >= 14 && rect.Height <= 96 &&
                        Math.Abs(rect.Width - rect.Height) < rect.Width * 0.25 && rect.Left >= rowRect.Left &&
                        rect.Right < rowRect.Left + rowRect.Width * 0.4 && rect.Top >= rowRect.Top && rect.Bottom <= rowRect.Bottom &&
                        !Has(id, "presence") && !Has(id, "availability")) { avatars.Add(rect); avatarNodes.Add(node); }
                }
            }
            AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(node, request);
            if (item.Item2 >= 8 && child != null) { complete = false; break; }
            int siblings = 0;
            for (; child != null && siblings++ < 64 && queue.Count < 128; child = TreeWalker.ControlViewWalker.GetNextSibling(child, request)) {
                queue.Enqueue(Tuple.Create(child, item.Item2 + 1));
            }
            if (child != null) { complete = false; break; }
        }
        if (queue.Count > 0) complete = false;
        if (!complete || people.Count != 1) return null;
        string identity = null;
        foreach (string person in people) identity = person;
        if (texts.Count > 1) {
            foreach (var text in texts) {
                if (Math.Abs(text.Top - texts[0].Top) > Math.Max(text.Height, texts[0].Height)) return null;
            }
        }
        foreach (var indicator in indicators) {
            var rect = indicator.Item2;
            if (texts.Count > 0 && !rect.IsEmpty && rect.Width > 0 && rect.Height > 0) {
                var text = texts[0];
                if (Math.Abs((rect.Top + rect.Height / 2) - (text.Top + text.Height / 2)) <= Math.Max(text.Height, rect.Height) * 0.75) states.Add(indicator.Item1);
            } else if (Row(rowInfo) && rowRect.Height <= 120 && PresenceText.ConversationIdentity(rowInfo.Name, identity)) {
                states.Add(indicator.Item1);
            }
        }
        // Text is interpreted as a status ONLY when explicitly labelled and
        // attached to the identified conversation row, never a message preview.
        string labelled = PresenceText.ConversationState(rowInfo.Name, identity);
        if (labelled != "Unknown") states.Add(labelled);
        string found = "Unknown";
        if (states.Count == 1) foreach (string state in states) found = state;
        string source = states.Count > 1 ? "Riga chat: indicatori discordanti" :
            (found == "Unknown" ? "Riga chat trovata; badge non esposto" : "Riga conversazione: indicatore accessibile");
        if (states.Count == 0 && visibleBadges && avatars.Count == 1 && texts.Count == 1 && avatars[0].Right <= texts[0].Left &&
            Math.Abs((avatars[0].Top + avatars[0].Height / 2) - (texts[0].Top + texts[0].Height / 2)) <= avatars[0].Height * 0.6) {
            // Teams can reorder/recycle rows while we inspect them. Revalidate
            // the exact text anchor and avatar bounds before AND after sampling.
            if (AnchorUnchanged(textNodes[0], avatarNodes[0], identity, avatars[0], request)) {
                found = VisiblePresenceBadge.Read(window, avatars[0]);
                if (!AnchorUnchanged(textNodes[0], avatarNodes[0], identity, avatars[0], request)) found = "Unknown";
            }
            source = found == "Unknown" ? "Riga chat trovata; badge coperto, non riconosciuto o non visibile" : "Riga conversazione: colore badge visibile (stima)";
        }
        return new RowReading { Person = identity, State = found, Source = source };
    }

    private static bool AnchorUnchanged(AutomationElement text, AutomationElement avatar, string identity,
        System.Windows.Rect bounds, CacheRequest request) {
        var label = text.GetUpdatedCache(request).Cached;
        var image = avatar.GetUpdatedCache(request).Cached;
        var rect = image.BoundingRectangle;
        return !label.IsOffscreen && !image.IsOffscreen && PresenceText.IsIdentity(label.Name, identity) &&
            rect.Left == bounds.Left && rect.Top == bounds.Top && rect.Width == bounds.Width && rect.Height == bounds.Height;
    }

    public static PresenceProbeResult Inspect(IntPtr window, string[] names, bool visibleBadges) {
        var result = new PresenceProbeResult { State = "Unknown", Contacts = new ContactPresenceReading[0], Diagnostic = "Colonna conversazioni non trovata" };
        var readings = new Dictionary<string, List<RowReading>>(StringComparer.OrdinalIgnoreCase);
        foreach (string name in names ?? new string[0]) if (!readings.ContainsKey(name)) readings.Add(name, new List<RowReading>());
        bool complete = true;
        int rows = 0;
        try {
            var request = Properties();
            var root = AutomationElement.FromHandle(window).GetUpdatedCache(request);
            var bounds = root.Cached.BoundingRectangle;
            var queue = new Queue<Tuple<AutomationElement, int, bool>>();
            queue.Enqueue(Tuple.Create(root, 0, false));
            Stopwatch budget = Stopwatch.StartNew();
            int visited = 0;
            double columnRight = double.NaN;
            while (queue.Count > 0 && visited++ < 1600 && budget.ElapsedMilliseconds < 4000) {
                var item = queue.Dequeue();
                var node = item.Item1;
                AutomationElement.AutomationElementInformation info;
                try { info = node.Cached; }
                catch (ElementNotAvailableException) { if (item.Item3) complete = false; continue; }
                catch (InvalidOperationException) { if (item.Item3) complete = false; continue; }
                if (Message(info.AutomationId)) continue;
                var rect = info.BoundingRectangle;
                // Do not traverse the selected conversation / profile on the right.
                if (item.Item2 > 0 && !rect.IsEmpty && rect.Width > 0 && rect.Left >= bounds.Left + bounds.Width * 0.55) continue;
                if (!item.Item3 && !double.IsNaN(columnRight) && !rect.IsEmpty && rect.Width > 0 && rect.Left >= columnRight) continue;
                bool column = item.Item3 || (InColumn(rect, bounds) && Column(info));
                if (column && InColumn(rect, bounds) && rect.Width >= 120 && rect.Height >= 60) {
                    columnRight = double.IsNaN(columnRight) ? rect.Right : Math.Max(columnRight, rect.Right);
                }
                bool candidate = Row(info) || ((info.ControlType == ControlType.Button || info.ControlType == ControlType.Group ||
                    info.ControlType == ControlType.Custom) && rect.Width >= 120);
                if (column && !info.IsOffscreen && InColumn(rect, bounds) && candidate && rect.Height >= 16 && rect.Height <= 200) {
                    rows++;
                    bool nested = false, rowComplete = true;
                    try {
                        var reading = ReadRow(node, names, request, window, visibleBadges, budget, out nested, out rowComplete);
                        if (reading != null) readings[reading.Person].Add(reading);
                        if (!rowComplete) complete = false;
                    } catch (ElementNotAvailableException) { complete = false; }
                      catch (InvalidOperationException) { complete = false; }
                    // Sections such as Favorites/Chat can also be TreeItems.
                    // Their child conversations must still be traversed.
                    if (!nested) continue;
                }
                // Once inside the column, offscreen/collapsed branches cannot
                // supply a visible badge and should not consume the scan budget.
                if (column && info.IsOffscreen) continue;
                AutomationElement child;
                try { child = TreeWalker.ControlViewWalker.GetFirstChild(node, request); }
                catch (ElementNotAvailableException) { if (column) complete = false; continue; }
                catch (InvalidOperationException) { if (column) complete = false; continue; }
                if (item.Item2 >= 40 && child != null) { if (column) complete = false; continue; }
                int siblings = 0;
                for (; child != null && siblings++ < 200 && queue.Count < 1600 && budget.ElapsedMilliseconds < 4000;
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child, request)) {
                    queue.Enqueue(Tuple.Create(child, item.Item2 + 1, column));
                }
                if (child != null) complete = false;
            }
            if (queue.Count > 0) complete = false;
            result.Diagnostic = complete ? ("Colonna conversazioni: " + rows + " righe visibili esaminate") : "Scansione colonna conversazioni incompleta";
        } catch (Exception exception) {
            complete = false;
            result.Diagnostic = "Lettura colonna conversazioni fallita: " + exception.GetType().Name;
        }
        var contacts = new List<ContactPresenceReading>();
        foreach (var pair in readings) {
            string state = "Unknown", detail = "Persona non trovata nella colonna chat visibile";
            if (!complete) detail = "Colonna chat in aggiornamento o scansione incompleta: riprova";
            else if (pair.Value.Count > 1) detail = "Piu righe corrispondono al nome: identita non univoca";
            else if (pair.Value.Count == 1) { state = pair.Value[0].State; detail = pair.Value[0].Source; }
            contacts.Add(new ContactPresenceReading { Name = pair.Key, State = state, Diagnostic = detail });
        }
        result.Contacts = contacts.ToArray();
        return result;
    }
}

public static class VisiblePresenceBadge {
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPhysicalPoint(Point point);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr bitmap);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr bitmap);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);

    // COLORREF pixels, sampled ONLY around the avatar's bottom-right badge.
    // A compact colored component is required; never infer Offline from gray.
    public static string Classify(uint[] colors, int side) {
        if (colors == null || side < 6 || side > 40 || colors.Length != side * side) return "Unknown";
        var kinds = new int[colors.Length];
        for (int i = 0; i < colors.Length; i++) {
            if (colors[i] == 0xffffffff) return "Unknown";
            int r = (int)(colors[i] & 255), g = (int)((colors[i] >> 8) & 255), b = (int)((colors[i] >> 16) & 255);
            if (g >= 100 && g > r * 1.35 && g > b * 1.2) kinds[i] = 1;
            else if (r >= 170 && g >= 110 && b < 110 && r > b * 1.6 && g > b * 1.4) kinds[i] = 2;
            else if (r >= 170 && r > g * 1.6 && r > b * 1.35) kinds[i] = 3;
        }
        int winner = 0, components = 0;
        var seen = new bool[colors.Length];
        for (int i = 0; i < kinds.Length; i++) {
            if (seen[i] || kinds[i] == 0) continue;
            int kind = kinds[i], count = 0, minX = side, minY = side, maxX = 0, maxY = 0;
            var queue = new Queue<int>(); queue.Enqueue(i); seen[i] = true;
            while (queue.Count > 0) {
                int pixel = queue.Dequeue(), x = pixel % side, y = pixel / side;
                count++; minX = Math.Min(minX, x); maxX = Math.Max(maxX, x); minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                foreach (int next in new int[] { pixel - 1, pixel + 1, pixel - side, pixel + side }) {
                    if (next < 0 || next >= kinds.Length || Math.Abs(next % side - x) + Math.Abs(next / side - y) != 1 || seen[next] || kinds[next] != kind) continue;
                    seen[next] = true; queue.Enqueue(next);
                }
            }
            int width = maxX - minX + 1, height = maxY - minY + 1;
            if (count < 6 || width < 3 || height < 3) continue;
            // Reject a photo/background swatch, clipped shapes and elongated marks.
            if (minX == 0 || minY == 0 || maxX == side - 1 || maxY == side - 1 || width > side * 0.85 || height > side * 0.85 ||
                width > height * 1.6 || height > width * 1.6 || count < width * height * 0.35) return "Unknown";
            components++; winner = kind;
        }
        if (components != 1) return "Unknown";
        return winner == 1 ? "Available" : (winner == 2 ? "Away" : "BusyOrDnd");
    }

    public static string Read(IntPtr window, System.Windows.Rect avatar) {
        IntPtr oldDpi = IntPtr.Zero, dc = IntPtr.Zero, memory = IntPtr.Zero, bitmap = IntPtr.Zero, oldBitmap = IntPtr.Zero;
        try {
            if (!IsWindowVisible(window) || IsIconic(window)) return "Unknown";
            oldDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
            if (oldDpi == IntPtr.Zero) return "Unknown";
            IntPtr root = GetAncestor(window, 2);
            if (root == IntPtr.Zero) return "Unknown";
            int side = Math.Max(10, Math.Min(40, (int)Math.Ceiling(avatar.Width * 0.6)));
            int left = (int)Math.Round(avatar.Right - side * 0.6), top = (int)Math.Round(avatar.Bottom - side * 0.6);
            dc = GetDC(IntPtr.Zero);
            if (dc == IntPtr.Zero) return "Unknown";
            for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
                var point = new Point { X = left + x, Y = top + y };
                if (GetAncestor(WindowFromPhysicalPoint(point), 2) != root) return "Unknown";
            }
            // One tiny screen copy, then read pixels from memory: avoid a GPU
            // synchronization for every individual screen GetPixel call.
            memory = CreateCompatibleDC(dc);
            if (memory == IntPtr.Zero) return "Unknown";
            bitmap = CreateCompatibleBitmap(dc, side, side);
            if (bitmap == IntPtr.Zero) return "Unknown";
            oldBitmap = SelectObject(memory, bitmap);
            if (oldBitmap == IntPtr.Zero || oldBitmap == new IntPtr(-1)) { oldBitmap = IntPtr.Zero; return "Unknown"; }
            if (!BitBlt(memory, 0, 0, side, side, dc, left, top, 0x00CC0020)) return "Unknown";
            var pixels = new uint[side * side];
            for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) pixels[y * side + x] = GetPixel(memory, x, y);
            // Recheck ownership after reading; never sample a covering app as Teams.
            for (int y = 0; y < side; y++) for (int x = 0; x < side; x++) {
                if (GetAncestor(WindowFromPhysicalPoint(new Point { X = left + x, Y = top + y }), 2) != root) return "Unknown";
            }
            return Classify(pixels, side);
        } catch (DllNotFoundException) { return "Unknown"; }
          catch (EntryPointNotFoundException) { return "Unknown"; }
        finally {
            if (oldBitmap != IntPtr.Zero) SelectObject(memory, oldBitmap);
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
            if (memory != IntPtr.Zero) DeleteDC(memory);
            if (dc != IntPtr.Zero) ReleaseDC(IntPtr.Zero, dc);
            if (oldDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(oldDpi);
        }
    }
}
}

using System;
using System.Text.RegularExpressions;

// Pure matching rules: never derive presence from message bodies or substrings.
public static class PresenceText {
    public static bool OwnAccount(string name, string id, bool header) {
        string accountId = (id ?? "").ToLowerInvariant();
        string label = (name ?? "").ToLowerInvariant();
        return accountId.Contains("me-control") || accountId.Contains("mectrl") || accountId.Contains("mecontrol") ||
            accountId.Contains("account-manager") ||
            (header && (accountId.Contains("personbutton") || label.Contains("account manager") || label.Contains("gestione account")));
    }

    public static string Clean(string value) {
        return Regex.Replace(value ?? String.Empty, @"\s+", " ").Trim();
    }

    public static string State(string value) {
        string text = Clean(value).Trim(' ', ',', '.', ':', ';', '|', '-', '(', ')');
        text = Regex.Replace(text, @"^(?:current\s+)?(?:status|stato|presence|presenza|availability|disponibilit[aà])(?:\s*:\s*|\s+)", "", RegexOptions.IgnoreCase);
        switch (text.ToLowerInvariant()) {
            case "available": case "disponibile": return "Available";
            case "away": case "assente": case "be right back": case "torno subito": return "Away";
            case "busy": case "occupato": case "in a call": case "in chiamata":
            case "in a meeting": case "in riunione": return "Busy";
            case "do not disturb": case "non disturbare": return "Dnd";
            case "offline": case "non in linea": case "appear offline": return "Offline";
            default: return "Unknown";
        }
    }

    public static string IdentityLabel(string value) {
        return Regex.Replace(Clean(value), @"^(?:profile picture of|profile of|foto del profilo di|immagine del profilo di|profilo di)\s+", "", RegexOptions.IgnoreCase);
    }

    public static bool IsIdentity(string value, string identity) {
        return String.Equals(IdentityLabel(value), Clean(identity), StringComparison.OrdinalIgnoreCase);
    }

    public static string NamedState(string value, string identity) {
        string text = IdentityLabel(value);
        string person = Clean(identity);
        if (person.Length < 3 || !text.StartsWith(person, StringComparison.OrdinalIgnoreCase) || text.Length <= person.Length) {
            return "Unknown";
        }
        char boundary = text[person.Length];
        if (!Char.IsWhiteSpace(boundary) && ",;:|-(".IndexOf(boundary) < 0) {
            return "Unknown";
        }
        return State(text.Substring(person.Length));
    }
}

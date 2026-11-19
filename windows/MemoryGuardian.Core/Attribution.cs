using System.Text.RegularExpressions;

namespace MemoryGuardian.Core;

public static partial class NodeService
{
    [GeneratedRegex(@"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+$")]
    private static partial Regex PackagePattern();

    private static ServiceInfo? Package(string token, string? entry)
    {
        int at = token.LastIndexOf('@');
        string name = at > 0 ? token[..at] : token;
        return PackagePattern().IsMatch(name) ? new("package:" + name.ToLowerInvariant(), name, entry) : null;
    }

    public static ServiceInfo? Parse(IReadOnlyList<string> arguments)
    {
        if (arguments.Count == 0) return null;
        if (arguments[0].StartsWith("npm exec ", StringComparison.OrdinalIgnoreCase))
            return Package(arguments[0][9..].Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "", null);
        for (int i = 1; i < arguments.Count; i++)
        {
            string a = arguments[i];
            if (a is "-e" or "--eval" or "-p" or "--print") return null;
            if (a.StartsWith('-')) continue;
            string normalized = a.Replace('\\', '/');
            string file = normalized.Split('/').Last();
            if (file.Equals("npm-cli.js", StringComparison.OrdinalIgnoreCase) ||
                file.Equals("npx-cli.js", StringComparison.OrdinalIgnoreCase))
            {
                int start = file.StartsWith("npm-", StringComparison.OrdinalIgnoreCase)
                    ? Enumerable.Range(i + 1, arguments.Count - i - 1).FirstOrDefault(j => arguments[j] == "exec", -1) + 1
                    : i + 1;
                if (start <= i) return null;
                for (int j = start; j < arguments.Count; j++)
                {
                    if (arguments[j] is "--yes" or "-y" or "--") continue;
                    return arguments[j].StartsWith('-') ? null : Package(arguments[j], null);
                }
                return null;
            }
            bool absolute = normalized.StartsWith("//") ||
                (normalized.Length > 2 && char.IsLetter(normalized[0]) && normalized[1..3] == ":/");
            if (!absolute) return null; // Relative paths have no verified process CWD; don't invent one.
            int modules = normalized.LastIndexOf("/node_modules/", StringComparison.OrdinalIgnoreCase);
            if (modules >= 0)
            {
                string[] parts = normalized[(modules + 14)..].Split('/');
                if (parts.Length == 0) return null;
                string token = parts[0] == ".bin" ? parts.ElementAtOrDefault(1) ?? "" :
                    parts[0].StartsWith('@') && parts.Length > 1 ? parts[0] + "/" + parts[1] : parts[0];
                return Package(token, a);
            }
            if (!new[] { ".js", ".mjs", ".cjs" }.Any(e => normalized.EndsWith(e, StringComparison.OrdinalIgnoreCase))) return null;
            string[] path = normalized.Split('/', StringSplitOptions.RemoveEmptyEntries);
            int directory = path.Length - 2;
            if (directory < 0) return null;
            if (new[] { "src", "dist", "scripts", "bin", "build" }.Contains(path[directory], StringComparer.OrdinalIgnoreCase)) directory--;
            string name = directory >= 0 ? path[directory] : file;
            return new("script:" + normalized.ToLowerInvariant(), name, a);
        }
        return null;
    }
}

public static class AppAggregator
{
    private static readonly HashSet<string> Shells = new(StringComparer.OrdinalIgnoreCase)
        { "explorer.exe", "svchost.exe", "services.exe", "wininit.exe", "winlogon.exe", "conhost.exe", "dwm.exe", "sihost.exe" };

    public static IReadOnlyList<AppMemory> Aggregate(IReadOnlyList<ProcessMemory> processes)
    {
        var byPid = processes.ToDictionary(p => p.Pid);
        var groups = new Dictionary<string, (ProcessMemory Root, List<ProcessMemory> Rows)>();
        foreach (var process in processes)
        {
            ProcessMemory root = process;
            var seen = new HashSet<int> { process.Pid };
            var cursor = process;
            ProcessMemory? windowOwner = cursor.HasWindow && !Shells.Contains(cursor.Name) ? cursor : null;
            while (windowOwner == null && byPid.TryGetValue(cursor.ParentPid, out var parent))
            {
                if (!seen.Add(parent.Pid)) { root = process; break; }
                // Unknown creation times cannot establish ancestry safely. A newer parent is a reused PID.
                if (cursor.Started == 0 || parent.Started == 0 || parent.Started > cursor.Started) break;
                if (Shells.Contains(parent.Name)) break;
                if (parent.HasWindow) { windowOwner = parent; break; }
                if (process.Executable != null && parent.Executable != null &&
                    string.Equals(parent.Executable, process.Executable, StringComparison.OrdinalIgnoreCase)) root = parent;
                cursor = parent;
            }
            root = windowOwner ?? root;
            string key = root.Identity;
            if (!groups.TryGetValue(key, out var group)) group = (root, []);
            group.Rows.Add(process); groups[key] = group;
        }
        return groups.Select(pair =>
        {
            var root = pair.Value.Root;
            string name = root.IsNode ? $"{root.Service?.Name ?? "来源未确认"} · Node · {root.Pid}" :
                root.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? root.Name[..^4] : root.Name;
            return new AppMemory(pair.Key, name, root, pair.Value.Rows);
        }).OrderByDescending(a => a.Bytes).ThenBy(a => a.Name).ToArray();
    }
}

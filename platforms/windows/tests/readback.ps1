# Lists the top-level app windows (-All: every visible top-level window, owned, untitled and tool windows too) and what a person would actually see of each.
# Run in the desktop session (exec -i). Output: one line per window, then a SEEN line.
param([switch]$All)
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class RB {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int sz);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L,T,R,B; }
  public static bool All = false; public static List<string> Rows = new List<string>(); public static List<string> Seen = new List<string>();
  public static void Run() {
    Rows.Clear(); Seen.Clear();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var t = new StringBuilder(256); GetWindowText(h, t, 256); if (t.Length == 0 && !All) return true;
      var c = new StringBuilder(128); GetClassName(h, c, 128);
      long ex = GetLong(h, -20).ToInt64();
      if (!All && (ex & 0x80) != 0 && (ex & 0x40000) == 0) return true;           // tool window
      if (!All && GetWindow(h, 4) != IntPtr.Zero && (ex & 0x40000) == 0) return true; // owned
      string cs = c.ToString(); if (!All && (cs == "Progman" || cs == "Shell_TrayWnd" || cs == "Windows.UI.Core.CoreWindow" || cs=="XamlExplorerHostIslandWindow")) return true;
      int cloaked; DwmGetWindowAttribute(h, 14, out cloaked, 4);
      RECT r; GetWindowRect(h, out r);
      int alpha = 255; if ((ex & 0x80000) != 0) { uint k, f; byte a; if (GetLayeredWindowAttributes(h, out k, out a, out f) && (f & 2) != 0) alpha = a; }
      bool parked = r.L <= -30000;
      bool seen = cloaked == 0 && alpha > 0 && !parked;
      string row = string.Format("w-{0} class={1} title='{2}' cloaked={3} alpha={4} parked={5} rect={6},{7} SEEN={8}", h.ToInt64(), cs, t, cloaked, alpha, parked, r.L, r.T, seen);
      Rows.Add(row); if (seen) Seen.Add(t.ToString());
      return true; }, IntPtr.Zero);
  }
}
'@
# This script runs elevated, and Windows hides a medium-integrity keyboard hook's input while an elevated
# window is in front (UIPI). Hand the foreground back to whatever had it so the next key press is seen.
$fg = [RB]::GetForegroundWindow()
[RB]::All = [bool]$All
[RB]::Run()
[RB]::Rows
"SEEN: " + (([RB]::Seen | Sort-Object) -join ' | ')

if ($fg -ne [IntPtr]::Zero) { [void][RB]::SetForegroundWindow($fg) }

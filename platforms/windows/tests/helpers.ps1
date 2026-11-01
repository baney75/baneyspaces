# Small things the live test does to a window from outside the daemon. Run in the desktop session.
# Usage: helpers.ps1 <command> <hwnd> [arg]
#   uncloak <hwnd>       the shell cloak off, as another tool or a virtual desktop switch would
#   cloaked <hwnd>       the DWM cloaked state (2 = shell)
#   settitle <hwnd> <t>  SetWindowText (an empty one makes the window fail a "has a title" check)
#   endsession <query|cancel>  send WM_QUERYENDSESSION / WM_ENDSESSION(false) to the daemon's hidden window
param([string]$Cmd, [long]$Hwnd = 0, [string]$Arg = '')
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IServiceProvider10 { [PreserveSig] int QueryService(ref Guid svc, ref Guid riid, out IntPtr obj); }
[ComImport, Guid("372E1D3B-38D3-42E4-A15B-8AB2B178F513"), InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
public interface IApplicationView {
  [PreserveSig] int SetFocus(); [PreserveSig] int SwitchTo(); [PreserveSig] int TryInvokeBack(IntPtr cb);
  [PreserveSig] int GetThumbnailWindow(out IntPtr h); [PreserveSig] int GetMonitor(out IntPtr m); [PreserveSig] int GetVisibility(out int v);
  [PreserveSig] int SetCloak(uint type, int flags);
}
[ComImport, Guid("1841c6d7-4f9d-42c0-af41-8747538f10e5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationViewCollection {
  [PreserveSig] int GetViews(out IntPtr a); [PreserveSig] int GetViewsByZOrder(out IntPtr a); [PreserveSig] int GetViewsByAumid([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr a);
  [PreserveSig] int GetViewForHwnd(IntPtr hwnd, out IApplicationView view);
}
public static class H {
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int sz);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool SetWindowTextW(IntPtr h, string t);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string t);
  [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static int Cloaked(long h) { int v; DwmGetWindowAttribute((IntPtr)h, 14, out v, 4); return v; }
  public static string Uncloak(long h) {
    var t = Type.GetTypeFromCLSID(new Guid("C2F03A33-21F5-47FA-B4BB-156362A2F239"));
    var sp = (IServiceProvider10)Activator.CreateInstance(t);
    var g = new Guid("1841c6d7-4f9d-42c0-af41-8747538f10e5"); IntPtr o; int hr = sp.QueryService(ref g, ref g, out o);
    var coll = (IApplicationViewCollection)Marshal.GetObjectForIUnknown(o);
    IApplicationView v; hr = coll.GetViewForHwnd((IntPtr)h, out v); if (hr != 0 || v == null) return "no view 0x" + hr.ToString("x");
    return "setcloak 0x" + v.SetCloak(1, 0).ToString("x");
  }
  public static bool SetTitle(long h, string t) { return SetWindowTextW((IntPtr)h, t); }
  public static string EndSession(bool cancel) {
    var w = FindWindowW("BaneySpacesSession", null); if (w == IntPtr.Zero) return "no session window";
    if (!cancel) return "query -> " + SendMessageW(w, 0x11, IntPtr.Zero, IntPtr.Zero);
    return "cancel -> " + SendMessageW(w, 0x16, IntPtr.Zero, IntPtr.Zero);
  }
}
'@
switch ($Cmd) {
  'uncloak'    { [H]::Uncloak($Hwnd) }
  'cloaked'    { [H]::Cloaked($Hwnd) }
  'settitle'   { [H]::SetTitle($Hwnd, $Arg) }
  'endsession' { [H]::EndSession($Arg -eq 'cancel') }
}

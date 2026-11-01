# Sends raw lines to the daemon's control pipe and prints each reply. For the test that a request which is
# valid JSON but not an object is refused without hurting the daemon.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($line in @('"x"', '[1]', '5', '{"op":"ping"}')) {
  $p = New-Object IO.Pipes.NamedPipeClientStream('.', "baneyspaces-$sid", 'InOut')
  $p.Connect(3000)
  $w = New-Object IO.StreamWriter($p); $w.AutoFlush = $true
  $r = New-Object IO.StreamReader($p)
  $w.WriteLine($line)
  $r.ReadLine()
  $p.Dispose()
}

param([string]$Version = "77")
$ports=@()
$f="C:\Sistemas\DoingLio\data\capitan\estado.json"
try {
  if(Test-Path $f){
    $st=Get-Content $f -Raw|ConvertFrom-Json
    $p=0
    if([int]::TryParse([string]$st.port,[ref]$p) -and $p -ge 1024 -and $p -le 65535){$ports+=$p}
  }
}catch{}
$ports+=@(8787,8797)
foreach($p in @($ports|Select-Object -Unique)){
  try {
    $h=Invoke-RestMethod -Uri ("http://127.0.0.1:"+$p+"/health") -TimeoutSec 1
    if($h.ok -and $h.service -eq "Capitan Rodolfo Local" -and
      [string]$h.version -eq $Version -and $h.apiSqlObject -eq $true){
      Write-Output $p
      exit 0
    }
  }catch{}
}
exit 1

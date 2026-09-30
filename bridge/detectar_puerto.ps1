param([string]$Version = "")
$ports=@()
if([string]::IsNullOrWhiteSpace($Version)){
  foreach($vf in @("C:\Sistemas\DoingLioConnector\VERSION",(Join-Path $PSScriptRoot '..\VERSION'))){
    try{
      if(Test-Path $vf){$Version=(Get-Content $vf -Raw).Trim();if($Version){break}}
    }catch{}
  }
}
$f="C:\Sistemas\DoingLio\data\capitan\estado.json"
try {
  if(Test-Path $f){
    $st=Get-Content $f -Raw|ConvertFrom-Json
    $p=0
    if([int]::TryParse([string]$st.port,[ref]$p) -and $p -ge 1024 -and $p -le 65535){$ports+=$p}
  }
}catch{}
$ports+=@(8787,8797,18787,27877,37877,48787,57877)
$found=@()
foreach($p in @($ports|Select-Object -Unique)){
  try {
    $h=Invoke-RestMethod -Uri ("http://127.0.0.1:"+$p+"/health") -TimeoutSec 1
    if($h.ok -and $h.service -eq "Capitan Rodolfo Local" -and $h.apiSqlObject -eq $true -and
      ([string]::IsNullOrWhiteSpace($Version) -or [string]$h.version -eq $Version)){
      $found+=@([pscustomobject]@{port=$p;connected=([bool]$h.connected);version=([int]$h.version)})
    }
  }catch{}
}
$selected=@($found|Sort-Object @{Expression='connected';Descending=$true},@{Expression='version';Descending=$true})|Select-Object -First 1
if($null -ne $selected){Write-Output $selected.port;exit 0}
exit 1

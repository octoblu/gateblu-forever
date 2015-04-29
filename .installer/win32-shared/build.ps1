param([String]$platform)

$ErrorActionPreference = "Stop"

function Get-ScriptDirectory
{
    $Invocation = (Get-Variable MyInvocation -Scope 1).Value;
    if($Invocation.PSScriptRoot)
    {
        $Invocation.PSScriptRoot;
    }
    Elseif($Invocation.MyCommand.Path)
    {
        Split-Path $Invocation.MyCommand.Path
    }
    else
    {
        $Invocation.InvocationName.Substring(0,$Invocation.InvocationName.LastIndexOf("\"));
    }
}

$script_dir = Get-ScriptDirectory
$shared_dir = "$script_dir\..\win32-shared"
$output_dir = "$script_dir\output"
$cache_dir = "$script_dir\cache"
$tmp_dir = [io.path]::GetTempFileName()
$wix_template_dir = "$shared_dir\wix"
$wix_dir="C:\Program Files\WiX Toolset v3.9\bin"

If ($platform -eq 'win32-x64') {
  $wix_dir="C:\Program Files (x86)\WiX Toolset v3.9\bin"
}

@(
    $output_dir
    $tmp_dir
) |
ForEach-Object {
  If (Test-Path $_) {
    Remove-Item $_ -Recurse -Force -ErrorAction Stop
  }
  mkdir $_ | Out-Null
}

If (!(Test-Path $cache_dir)){
  mkdir $cache_dir | Out-Null
}

@(
    'node.exe'
    'npm-2.6.0.zip'
    'nssm.exe'
) |
Where-Object { (!(Test-Path $cache_dir\$_)) } |
ForEach-Object {
  $source = "https://s3-us-west-2.amazonaws.com/gateblu/node-binaries/$platform/$_"
  $destination = "$cache_dir\$_"
  Invoke-WebRequest $source -OutFile $destination
}

If (!(Test-Path $cache_dir\npm)){
  echo "Installing npm..."
  mkdir $cache_dir\npm | Out-Null
  $shell = new-object -com shell.application
  $zip = $shell.NameSpace("$cache_dir\npm-2.6.0.zip")
  foreach($item in $zip.items())
  {
    $shell.Namespace("$cache_dir\npm").copyhere($item)
  }
  Copy-Item $cache_dir\npm\npm-2.6.0\bin\npm.cmd $cache_dir
  robocopy $cache_dir\npm\npm-2.6.0 $cache_dir\node_modules\npm /S /NFL /NDL /NS /NC /NJH /NJS
}

echo "Copying to $tmp_dir..."
#Copy excluding .git and installer
robocopy $script_dir\..\.. $tmp_dir /S /NFL /NDL /NS /NC /NJH /NJS /XD .git installer .installer coverage test node_modules
robocopy $cache_dir\node_modules $tmp_dir\node_modules /S /NFL /NDL /NS /NC /NJH /NJS
robocopy $shared_dir\assets $tmp_dir /S /NFL /NDL /NS /NC /NJH /NJS

Copy-Item $cache_dir\npm.cmd $tmp_dir\npm.cmd

echo "Installing node_modules..."
Set-Location -Path $tmp_dir
. "$cache_dir\npm.cmd" install -s
Set-Location -Path $script_dir\..\..

#Generate the installer
. $wix_dir\heat.exe dir $tmp_dir -srd -dr INSTALLDIR -cg MainComponentGroup -out $shared_dir\wix\directory.wxs -ke -sfrag -gg -var var.SourceDir -sreg -scom
. $wix_dir\candle.exe -dCacheDir="$cache_dir" -dSourceDir="$tmp_dir" $wix_template_dir\*.wxs -o $output_dir\\ -ext WiXUtilExtension
. $wix_dir\light.exe -o $output_dir\GatebluService.msi $output_dir\*.wixobj -cultures:en-US -ext WixUIExtension.dll -ext WiXUtilExtension

# Optional digital sign the certificate.
# You have to previously import it.
#. "C:\Program Files (x86)\Microsoft SDKs\Windows\v7.1A\Bin\signtool.exe" sign /n "Auth10" .\output\installer.msi

#Remove the temp
Remove-Item -Recurse -Force $tmp_dir

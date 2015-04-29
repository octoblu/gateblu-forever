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
$output_dir = "$script_dir\output"
$platform = 'win32-ia32'
$cache_dir = "$script_dir\cache"
$tmp_dir = [io.path]::GetTempFileName()

Remove-Item $output_dir -Recurse -Force -ErrorAction Stop
mkdir $output_dir

Remove-Item $tmp_dir
mkdir $tmp_dir

If (!(Test-Path $cache_dir)){
  mkdir $cache_dir
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
  mkdir $cache_dir\npm
  $shell = new-object -com shell.application
  $zip = $shell.NameSpace("$cache_dir\npm-2.6.0.zip")
  foreach($item in $zip.items())
  {
    $shell.Namespace("$cache_dir\npm").copyhere($item)
  }
}


#Copy excluding .git and installer
robocopy $script_dir\..\.. $tmp_dir /S /NFL /NDL /NS /NC /NJH /NJS /XD .git installer .installer coverage test node_modules
Copy-Item "$cache_dir\node.exe" $tmp_dir\node.exe
Copy-Item "$cache_dir\nssm.exe" $tmp_dir\nssm.exe
Copy-Item "$cache_dir\npm\npm-2.6.0\bin\npm.cmd" $tmp_dir\npm.cmd
robocopy $cache_dir\npm\npm-2.6.0 $tmp_dir\node_modules\npm /S /NFL /NDL /NS /NC /NJH /NJS
robocopy $script_dir\assets $tmp_dir /S /NFL /NDL /NS /NC /NJH /NJS

Set-Location -Path $tmp_dir
. $tmp_dir\npm.cmd install -s
Set-Location -Path $script_dir\..\..

#Generate the installer
$wix_dir="C:\Program Files\WiX Toolset v3.9\bin"

. "$wix_dir\heat.exe" dir $tmp_dir -srd -dr INSTALLDIR -cg MainComponentGroup -out $script_dir\directory.wxs -ke -sfrag -gg -var var.SourceDir -sreg -scom
. "$wix_dir\candle.exe" -dSourceDir="$tmp_dir" $script_dir\*.wxs -o $output_dir\ -ext WiXUtilExtension
. "$wix_dir\light.exe" -o $output_dir\GatebluService.msi $output_dir\*.wixobj -cultures:en-US -ext WixUIExtension.dll -ext WiXUtilExtension

# Optional digital sign the certificate.
# You have to previously import it.
#. "C:\Program Files (x86)\Microsoft SDKs\Windows\v7.1A\Bin\signtool.exe" sign /n "Auth10" .\output\installer.msi

#Remove the temp
Remove-Item -Recurse -Force $tmp_dir

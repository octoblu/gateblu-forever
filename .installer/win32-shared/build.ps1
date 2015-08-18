param([String]$platform)

$ErrorActionPreference = "Continue"

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
$cache_dir = "$script_dir\..\cache\$platform"
$tmp_dir = [io.path]::GetTempFileName()
$wix_template_dir = "$shared_dir\wix"
$wix_dir = "C:\Program Files (x86)\WiX Toolset v3.9\bin"

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
    'npm-2.10.1.zip'
) |
Where-Object { (!(Test-Path $cache_dir\$_)) } |
ForEach-Object {
  $source = "https://s3-us-west-2.amazonaws.com/gateblu/node-binaries/$platform/$_"
  $destination = "$cache_dir\$_"
  echo "Downloading $cache_dir\$_..."
  Invoke-WebRequest $source -OutFile $destination
}

If (!(Test-Path $cache_dir\npm)){
  echo "Installing npm ($cache_dir)..."
  pushd $cache_dir
  7z -y x $cache_dir\npm-2.10.1.zip | Out-Null
  popd
  Copy-Item $cache_dir\npm-2.10.1\bin\npm.cmd $cache_dir
  echo "Copying npm-2.10.1"
  robocopy $cache_dir\npm-2.10.1 $cache_dir\node_modules\npm /S /NFL /NDL /NS /NC /NJH /NJS
}

echo "Copying to $tmp_dir..."
#Copy excluding .git and installer
robocopy $script_dir\..\.. $tmp_dir /S /NFL /NDL /NS /NC /NJH /NJS /XD .git installer .installer coverage test node_modules
robocopy $cache_dir\node_modules $tmp_dir\node_modules /S /NFL /NDL /NS /NC /NJH /NJS
robocopy $shared_dir\assets $tmp_dir /S /NFL /NDL /NS /NC /NJH /NJS

Copy-Item $cache_dir\npm.cmd $tmp_dir\npm.cmd

echo "Adding GatebluServiceTray..."
$source = "https://s3-us-west-2.amazonaws.com/gateblu/gateblu-service-tray/latest/GatebluServiceTray-$platform.zip"
$destination = "$tmp_dir\GatebluServiceTray.zip"
echo "Downloading $tmp_dir\GatebluServiceTray.zip..."
Invoke-WebRequest $source -OutFile $destination
pushd $tmp_dir
7z -y x $tmp_dir\GatebluServiceTray.zip | Out-Null
popd
Remove-Item $tmp_dir\GatebluServiceTray.zip -Force -Recurse

echo "Installing node_modules..."
pushd $tmp_dir
. "$cache_dir\npm.cmd" install crossyio-unpack
. "$cache_dir\npm.cmd" install -s --production
popd

#Generate the installer
. $wix_dir\heat.exe dir $tmp_dir -srd -dr INSTALLDIR -cg MainComponentGroup -out $shared_dir\wix\directory.wxs -ke -sfrag -gg -var var.SourceDir -sreg -scom
. $wix_dir\candle.exe -dCacheDir="$cache_dir" -dSourceDir="$tmp_dir" $wix_template_dir\*.wxs -o $output_dir\\ -ext WiXUtilExtension
. $wix_dir\light.exe -o $output_dir\GatebluService-$platform.msi $output_dir\*.wixobj -cultures:en-US -ext WixUIExtension.dll -ext WiXUtilExtension

# Optional digital sign the certificate.
# You have to previously import it.
#. "C:\Program Files (x86)\Microsoft SDKs\Windows\v7.1A\Bin\signtool.exe" sign /n "Auth10" .\output\installer.msi

#Remove the temp
Remove-Item $tmp_dir -Recurse -Force

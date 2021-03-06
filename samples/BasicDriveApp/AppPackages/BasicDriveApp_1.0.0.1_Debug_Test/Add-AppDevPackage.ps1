#
# Add-AppxDevPackage.ps1 is a PowerShell script designed to install app
# packages created by Visual Studio for developers.  To run this script from
# Explorer, right-click on its icon and choose "Run with PowerShell".
#
# Visual Studio supplies this script in the folder generated with its
# "Prepare Package" command.  The same folder will also contain the app
# package (a .appx file), the signing certificate (a .cer file), and a
# "Dependencies" subfolder containing all the framework packages used by the
# app.
#
# This script simplifies installing these packages by automating the
# following functions:
#   1. Find the app package and signing certificate in the script directory
#   2. Prompt the user to acquire a developer license and to install the
#      certificate if necessary
#   3. Find dependency packages that are applicable to the operating system's
#      CPU architecture
#   4. Install the package along with all applicable dependencies
#
# All command line parameters are reserved for use internally by the script.
# Users should launch this script from Explorer.
#

# .Link
# http://go.microsoft.com/fwlink/?LinkId=243053

param(
    [switch]$Force = $false,
    [switch]$GetDeveloperLicense = $false,
    [string]$CertificatePath = $null
)

$ErrorActionPreference = "Stop"

# The language resources for this script are placed in the
# "Add-AppDevPackage.resources" subfolder alongside the script.  Since the
# current working directory might not be the directory that contains the
# script, we need to create the full path of the resources directory to
# pass into Import-LocalizedData
$ScriptPath = $null
try
{
    $ScriptPath = (Get-Variable MyInvocation).Value.MyCommand.Path
    $ScriptDir = Split-Path -Parent $ScriptPath
}
catch {}

if (!$ScriptPath)
{
    PrintMessageAndExit $UiStrings.ErrorNoScriptPath $ErrorCodes.NoScriptPath
}

$LocalizedResourcePath = Join-Path $ScriptDir "Add-AppDevPackage.resources"
Import-LocalizedData -BindingVariable UiStrings -BaseDirectory $LocalizedResourcePath

$ErrorCodes = Data {
    ConvertFrom-StringData @'
    Success = 0
    NoScriptPath = 1
    NoPackageFound = 2
    ManyPackagesFound = 3
    NoCertificateFound = 4
    ManyCertificatesFound = 5
    BadCertificate = 6
    PackageUnsigned = 7
    CertificateMismatch = 8
    ForceElevate = 9
    LaunchAdminFailed = 10
    GetDeveloperLicenseFailed = 11
    InstallCertificateFailed = 12
    AddPackageFailed = 13
    ForceDeveloperLicense = 14
    CertUtilInstallFailed = 17
    CertIsCA = 18
    BannedEKU = 19
    NoBasicConstraints = 20
    NoCodeSigningEku = 21
    InstallCertificateCancelled = 22
    BannedKeyUsage = 23
    ExpiredCertificate = 24
'@
}

function PrintMessageAndExit($ErrorMessage, $ReturnCode)
{
    Write-Host $ErrorMessage
    if (!$Force)
    {
        Pause
    }
    exit $ReturnCode
}

#
# Warns the user about installing certificates, and presents a Yes/No prompt
# to confirm the action.  The default is set to No.
#
function ConfirmCertificateInstall
{
    $Answer = $host.UI.PromptForChoice(
                    "", 
                    $UiStrings.WarningInstallCert, 
                    [System.Management.Automation.Host.ChoiceDescription[]]@($UiStrings.PromptYesString, $UiStrings.PromptNoString), 
                    1)
    
    return $Answer -eq 0
}

#
# Validates whether a file is a valid certificate using CertUtil.
# This needs to be done before calling Get-PfxCertificate on the file, otherwise
# the user will get a cryptic "Password: " prompt for invalid certs.
#
function ValidateCertificateFormat($FilePath)
{
    # certutil -verify prints a lot of text that we don't need, so it's redirected to $null here
    certutil.exe -verify $FilePath > $null
    if ($LastExitCode -lt 0)
    {
        PrintMessageAndExit ($UiStrings.ErrorBadCertificate -f $FilePath, $LastExitCode) $ErrorCodes.BadCertificate
    }
    
    # Check if certificate is expired
    $cert = Get-PfxCertificate $FilePath
    if (($cert.NotBefore -gt (Get-Date)) -or ($cert.NotAfter -lt (Get-Date)))
    {
        PrintMessageAndExit ($UiStrings.ErrorExpiredCertificate -f $FilePath) $ErrorCodes.ExpiredCertificate
    }
}

#
# Verify that the developer certificate meets the following restrictions:
#   - The certificate must contain a Basic Constraints extension, and its
#     Certificate Authority (CA) property must be false.
#   - The certificate's Key Usage extension must be either absent, or set to
#     only DigitalSignature.
#   - The certificate must contain an Extended Key Usage (EKU) extension with
#     Code Signing usage.
#   - The certificate must NOT contain any other EKU except Code Signing and
#     Lifetime Signing.
#
# These restrictions are enforced to decrease security risks that arise from
# trusting digital certificates.
#
function CheckCertificateRestrictions
{
    Set-Variable -Name BasicConstraintsExtensionOid -Value "2.5.29.19" -Option Constant
    Set-Variable -Name KeyUsageExtensionOid -Value "2.5.29.15" -Option Constant
    Set-Variable -Name EkuExtensionOid -Value "2.5.29.37" -Option Constant
    Set-Variable -Name CodeSigningEkuOid -Value "1.3.6.1.5.5.7.3.3" -Option Constant
    Set-Variable -Name LifetimeSigningEkuOid -Value "1.3.6.1.4.1.311.10.3.13" -Option Constant

    $CertificateExtensions = (Get-PfxCertificate $CertificatePath).Extensions
    $HasBasicConstraints = $false
    $HasCodeSigningEku = $false

    foreach ($Extension in $CertificateExtensions)
    {
        # Certificate must contain the Basic Constraints extension
        if ($Extension.oid.value -eq $BasicConstraintsExtensionOid)
        {
            # CA property must be false
            if ($Extension.CertificateAuthority)
            {
                PrintMessageAndExit $UiStrings.ErrorCertIsCA $ErrorCodes.CertIsCA
            }
            $HasBasicConstraints = $true
        }

        # If key usage is present, it must be set to digital signature
        elseif ($Extension.oid.value -eq $KeyUsageExtensionOid)
        {
            if ($Extension.KeyUsages -ne "DigitalSignature")
            {
                PrintMessageAndExit ($UiStrings.ErrorBannedKeyUsage -f $Extension.KeyUsages) $ErrorCodes.BannedKeyUsage
            }
        }

        elseif ($Extension.oid.value -eq $EkuExtensionOid)
        {
            # Certificate must contain the Code Signing EKU
            $EKUs = $Extension.EnhancedKeyUsages.Value
            if ($EKUs -contains $CodeSigningEkuOid)
            {
                $HasCodeSigningEKU = $True
            }

            # EKUs other than code signing and lifetime signing are not allowed
            foreach ($EKU in $EKUs)
            {
                if ($EKU -ne $CodeSigningEkuOid -and $EKU -ne $LifetimeSigningEkuOid)
                {
                    PrintMessageAndExit ($UiStrings.ErrorBannedEKU -f $EKU) $ErrorCodes.BannedEKU
                }
            }
        }
    }

    if (!$HasBasicConstraints)
    {
        PrintMessageAndExit $UiStrings.ErrorNoBasicConstraints $ErrorCodes.NoBasicConstraints
    }
    if (!$HasCodeSigningEKU)
    {
        PrintMessageAndExit $UiStrings.ErrorNoCodeSigningEku $ErrorCodes.NoCodeSigningEku
    }
}

#
# Performs operations that require administrative privileges:
#   - Prompt the user to obtain a developer license
#   - Install the developer certificate (if -Force is not specified, also prompts the user to confirm)
#
function DoElevatedOperations
{
    if ($GetDeveloperLicense)
    {
        Write-Host $UiStrings.GettingDeveloperLicense

        if ($Force)
        {
            PrintMessageAndExit $UiStrings.ErrorForceDeveloperLicense $ErrorCodes.ForceDeveloperLicense
        }
        try
        {
            Show-WindowsDeveloperLicenseRegistration
        }
        catch
        {
            $Error[0] # Dump details about the last error
            PrintMessageAndExit $UiStrings.ErrorGetDeveloperLicenseFailed $ErrorCodes.GetDeveloperLicenseFailed
        }
    }

    if ($CertificatePath)
    {
        Write-Host $UiStrings.InstallingCertificate

        # Make sure certificate format is valid and usage constraints are followed
        ValidateCertificateFormat $CertificatePath
        CheckCertificateRestrictions

        # If -Force is not specified, warn the user and get consent
        if ($Force -or (ConfirmCertificateInstall))
        {
            # Add cert to store
            certutil.exe -addstore TrustedPeople $CertificatePath
            if ($LastExitCode -lt 0)
            {
                PrintMessageAndExit ($UiStrings.ErrorCertUtilInstallFailed -f $LastExitCode) $ErrorCodes.CertUtilInstallFailed
            }
        }
        else
        {
            PrintMessageAndExit $UiStrings.ErrorInstallCertificateCancelled $ErrorCodes.InstallCertificateCancelled
        }
    }
}

#
# Checks whether the machine is missing a valid developer license.
#
function CheckIfNeedDeveloperLicense
{
    $Result = $true
    try
    {
        $Result = (Get-WindowsDeveloperLicense | Where-Object { $_.IsValid }).Count -eq 0
    }
    catch {}

    return $Result
}

#
# Launches an elevated process running the current script to perform tasks
# that require administrative privileges.  This function waits until the
# elevated process terminates, and checks whether those tasks were successful.
#
function LaunchElevated
{
    # Set up command line arguments to the elevated process
    $RelaunchArgs = '-ExecutionPolicy Unrestricted -file "' + $ScriptPath + '"'

    if ($Force)
    {
        $RelaunchArgs += ' -Force'
    }
    if ($NeedDeveloperLicense)
    {
        $RelaunchArgs += ' -GetDeveloperLicense'
    }
    if ($NeedInstallCertificate)
    {
        $RelaunchArgs += ' -CertificatePath "' + $DeveloperCertificatePath.FullName + '"'
    }

    # Launch the process and wait for it to finish
    try
    {
        $AdminProcess = Start-Process "$PsHome\PowerShell.exe" -Verb RunAs -ArgumentList $RelaunchArgs -PassThru
    }
    catch
    {
        $Error[0] # Dump details about the last error
        PrintMessageAndExit $UiStrings.ErrorLaunchAdminFailed $ErrorCodes.LaunchAdminFailed
    }

    while (!($AdminProcess.HasExited))
    {
        Start-Sleep -Seconds 2
    }

    # Check if all elevated operations were successful
    if ($NeedDeveloperLicense)
    {
        if (CheckIfNeedDeveloperLicense)
        {
            PrintMessageAndExit $UiStrings.ErrorGetDeveloperLicenseFailed $ErrorCodes.GetDeveloperLicenseFailed
        }
        else
        {
            Write-Host $UiStrings.AcquireLicenseSuccessful
        }
    }
    if ($NeedInstallCertificate)
    {
        $Signature = Get-AuthenticodeSignature $DeveloperPackagePath -Verbose
        if ($Signature.Status -ne "Valid")
        {
            PrintMessageAndExit ($UiStrings.ErrorInstallCertificateFailed -f $Signature.Status) $ErrorCodes.InstallCertificateFailed
        }
        else
        {
            Write-Host $UiStrings.InstallCertificateSuccessful
        }
    }
}

#
# Finds all applicable dependency packages according to OS architecture, and
# installs the developer package with its dependencies.  The expected layout
# of dependencies is:
#
# <current dir>
#     \Dependencies
#         <Architecture neutral dependencies>.appx
#         \x86
#             <x86 dependencies>.appx
#         \x64
#             <x64 dependencies>.appx
#         \arm
#             <arm dependencies>.appx
#
function InstallPackageWithDependencies
{
    $DependencyPackagesDir = (Join-Path $ScriptDir "Dependencies")
    $DependencyPackages = @()
    if (Test-Path $DependencyPackagesDir)
    {
        # Get architecture-neutral dependencies
        $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "*.appx") | Where-Object { $_.Mode -NotMatch "d" }

        # Get architecture-specific dependencies
        if (($Env:Processor_Architecture -eq "x86" -or $Env:Processor_Architecture -eq "amd64") -and (Test-Path (Join-Path $DependencyPackagesDir "x86")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x86\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if (($Env:Processor_Architecture -eq "amd64") -and (Test-Path (Join-Path $DependencyPackagesDir "x64")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x64\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if (($Env:Processor_Architecture -eq "arm") -and (Test-Path (Join-Path $DependencyPackagesDir "arm")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "arm\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        }
    }
    Write-Host $UiStrings.InstallingPackage

    $AddPackageSucceeded = $False
    try
    {
        if ($DependencyPackages.FullName.Count -gt 0)
        {
            Write-Host $UiStrings.DependenciesFound
            $DependencyPackages.FullName
            Add-AppxPackage -Path $DeveloperPackagePath.FullName -DependencyPath $DependencyPackages.FullName -ForceApplicationShutdown
        }
        else
        {
            Add-AppxPackage -Path $DeveloperPackagePath.FullName -ForceApplicationShutdown
        }
        $AddPackageSucceeded = $?
    }
    catch
    {
        $Error[0] # Dump details about the last error
    }

    if (!$AddPackageSucceeded)
    {
        if ($NeedInstallCertificate)
        {
            PrintMessageAndExit $UiStrings.ErrorAddPackageFailedWithCert $ErrorCodes.AddPackageFailed
        }
        else
        {
            PrintMessageAndExit $UiStrings.ErrorAddPackageFailed $ErrorCodes.AddPackageFailed
        }
    }
}

#
# Main script logic when the user launches the script without parameters.
#
function DoStandardOperations
{
    # List all .appx files in the script directory
    $PackagePath = Get-ChildItem (Join-Path $ScriptDir "*.appx") | Where-Object { $_.Mode -NotMatch "d" }

    # List all .appxbundle files in the script directory
    $BundlePath = Get-ChildItem (Join-Path $ScriptDir "*.appxbundle") | Where-Object { $_.Mode -NotMatch "d" }

    $NumberOfPackages = $PackagePath.Count + $BundlePath.Count;

    # There must be exactly 1 package/bundle
    if ($NumberOfPackages -lt 1)
    {
        PrintMessageAndExit $UiStrings.ErrorNoPackageFound $ErrorCodes.NoPackageFound
    }
    elseif ($NumberOfPackages -gt 1)
    {
        PrintMessageAndExit $UiStrings.ErrorManyPackagesFound $ErrorCodes.ManyPackagesFound
    }

    if ($PackagePath.Count -eq 1)
    {
        $DeveloperPackagePath = $PackagePath
        Write-Host ($UiStrings.PackageFound -f $DeveloperPackagePath.FullName)
    }
    else
    {
        $DeveloperPackagePath = $BundlePath
        Write-Host ($UiStrings.BundleFound -f $DeveloperPackagePath.FullName)
    }

    # The package must be signed
    $PackageSignature = Get-AuthenticodeSignature $DeveloperPackagePath
    $PackageCertificate = $PackageSignature.SignerCertificate
    if (!$PackageCertificate)
    {
        PrintMessageAndExit $UiStrings.ErrorPackageUnsigned $ErrorCodes.PackageUnsigned
    }

    # Test if the package signature is trusted.  If not, the corresponding certificate
    # needs to be present in the current directory and needs to be installed.
    $NeedInstallCertificate = ($PackageSignature.Status -ne "Valid")

    if ($NeedInstallCertificate)
    {
        # List all .cer files in the script directory
        $DeveloperCertificatePath = Get-ChildItem (Join-Path $ScriptDir "*.cer") | Where-Object { $_.Mode -NotMatch "d" }

        # There must be exactly 1 certificate
        if ($DeveloperCertificatePath.Count -lt 1)
        {
            PrintMessageAndExit $UiStrings.ErrorNoCertificateFound $ErrorCodes.NoCertificateFound
        }
        elseif ($DeveloperCertificatePath.Count -gt 1)
        {
            PrintMessageAndExit $UiStrings.ErrorManyCertificatesFound $ErrorCodes.ManyCertificatesFound
        }

        Write-Host ($UiStrings.CertificateFound -f $DeveloperCertificatePath.FullName)

        # The .cer file must have the format of a valid certificate
        ValidateCertificateFormat $DeveloperCertificatePath

        # The package signature must match the certificate file
        if ($PackageCertificate -ne (Get-PfxCertificate $DeveloperCertificatePath))
        {
            PrintMessageAndExit $UiStrings.ErrorCertificateMismatch $ErrorCodes.CertificateMismatch
        }
    }

    $NeedDeveloperLicense = CheckIfNeedDeveloperLicense

    # Relaunch the script elevated with the necessary parameters if needed
    if ($NeedDeveloperLicense -or $NeedInstallCertificate)
    {
        Write-Host $UiStrings.ElevateActions
        if ($NeedDeveloperLicense)
        {
            Write-Host $UiStrings.ElevateActionDevLicense
        }
        if ($NeedInstallCertificate)
        {
            Write-Host $UiStrings.ElevateActionCertificate
        }

        $IsAlreadyElevated = ([Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value -contains "S-1-5-32-544")
        if ($IsAlreadyElevated)
        {
            if ($Force -and $NeedDeveloperLicense)
            {
                PrintMessageAndExit $UiStrings.ErrorForceDeveloperLicense $ErrorCodes.ForceDeveloperLicense
            }
            if ($Force -and $NeedInstallCertificate)
            {
                Write-Warning $UiStrings.WarningInstallCert
            }
        }
        else
        {
            if ($Force)
            {
                PrintMessageAndExit $UiStrings.ErrorForceElevate $ErrorCodes.ForceElevate
            }
            else
            {
                Write-Host $UiStrings.ElevateActionsContinue
                Pause
            }
        }

        LaunchElevated
    }

    InstallPackageWithDependencies
}

#
# Main script entry point
#
if ($GetDeveloperLicense -or $CertificatePath)
{
    DoElevatedOperations
}
else
{
    DoStandardOperations
    PrintMessageAndExit $UiStrings.Success $ErrorCodes.Success
}

# SIG # Begin signature block
# MIIhrgYJKoZIhvcNAQcCoIIhnzCCIZsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDr6TQeGU6q8Gc6
# 4UyJ3BErCSyDb5bOOr9muAPuxnPhgKCCCzAwggS4MIIDoKADAgECAhMzAAAAFhEE
# tIg4jL7DAAAAAAAWMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTAwHhcNMTIwODMwMTc0OTAzWhcNMTMxMTMwMTc0OTAzWjCBgzEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjENMAsGA1UECxMETU9Q
# UjEeMBwGA1UEAxMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMIIBIjANBgkqhkiG9w0B
# AQEFAAOCAQ8AMIIBCgKCAQEAoFCfHU6UugcK3L6WSeE9oAbvlb75vVYqW5zvHhEu
# xtbhLbJvzDMtnh6ksYIWymQxqYomgfTjLvIeDhzI4Vnh1CM9ZXf/6uW3s40I9hLX
# b0lXpIXjBB7QQqinstswChXRyTVtf7yGXqU+tpBkBSQcPqBxaAox937Ulektm8pl
# BXoUAgwJ9rPdcV0mH1oLLwm6ZzJsnBXYnDyJ6Ec676YU30I+IR67MeIs0VT26oCS
# K5M0d22SZyY2wSox23gTSauTldxsqgwAccDNzd1j7ZFXl6+MKoTF3g11ZYzg0R9B
# O7u1ktJpOXWYAExsTD0YQwPOZjucXU5ReJFCO37QWuBfQwIDAQABo4IBJzCCASMw
# HwYDVR0lBBgwFgYIKwYBBQUHAwMGCisGAQQBgjc9BgEwHQYDVR0OBBYEFGvZ8Xb4
# o3g0pPdGnifxsLlszzamMB8GA1UdIwQYMBaAFOb8X3u7IgBY5HJOtfQhdCMy5u+s
# MFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kv
# Y3JsL3Byb2R1Y3RzL01pY0NvZFNpZ1BDQV8yMDEwLTA3LTA2LmNybDBaBggrBgEF
# BQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2kvY2VydHMvTWljQ29kU2lnUENBXzIwMTAtMDctMDYuY3J0MAwGA1UdEwEB/wQC
# MAAwDQYJKoZIhvcNAQELBQADggEBAFJC8724+Xy7MrKL26QtkBCpQrdInr35S1zM
# IWCkvYCXYy4qifab1rwikgFznoP78otrvTBa7O0wPu7I4X+oNyn3TB+t3iPXKm0l
# CtEwPkPxqrVFOKtuROPQoQMz11o05SExK44oLnjtZXIHh7X+vBbErC9ky6LNyeoH
# anVi68zmZqk8wTI5xdHAbGv6BTwrbbP7R/26vByAXRKG1Cva0iwoMn1XBYQngR/w
# QWVSAfBqr3kNuO3AY6dE1vmeAlVFDnheXNsAeullJHMSeLZQ+TYmSJQE7dhA1eE9
# QzcfmEWdLOM22nMwVJdqHiBcE/kO2Iwwtus+dYSl62OSCi1JS7YwggZwMIIEWKAD
# AgECAgphDFJMAAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBD
# ZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0xMDA3MDYyMDQwMTdaFw0yNTA3
# MDYyMDUwMTdaMH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTAwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDpDmRQeWe1xOP9CQBMnpSs91Zo6kTY
# z8VYT6mldnxtRbrTOZK0pB75+WWC5BfSj/1EnAjoZZPOLFWEv30I4y4rqEErGLei
# S25JTGsVB97R0sKJHnGUzbV/S7SvCNjMiNZrF5Q6k84mP+zm/jSYV9UdXUn2siou
# 1YW7WT/4kLQrg3TKK7M7RuPwRknBF2ZUyRy9HcRVYldy+Ge5JSA03l2mpZVeqyiA
# zdWynuUDtWPTshTIwciKJgpZfwfs/w7tgBI1TBKmvlJb9aba4IsLSHfWhUfVELnG
# 6Krui2otBVxgxrQqW5wjHF9F4xoUHm83yxkzgGqJTaNqZmN4k9Uwz5UfAgMBAAGj
# ggHjMIIB3zAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU5vxfe7siAFjkck61
# 9CF0IzLm76wwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwgZ0GA1UdIASB
# lTCBkjCBjwYJKwYBBAGCNy4DMIGBMD0GCCsGAQUFBwIBFjFodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vUEtJL2RvY3MvQ1BTL2RlZmF1bHQuaHRtMEAGCCsGAQUFBwIC
# MDQeMiAdAEwAZQBnAGEAbABfAFAAbwBsAGkAYwB5AF8AUwB0AGEAdABlAG0AZQBu
# AHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQAadO9XTyl7xBaFeLhQ0yL8CZ2sgpf4
# NP8qLJeVEuXkv8+/k8jjNKnbgbjcHgC+0jVvr+V/eZV35QLU8evYzU4eG2Giwloj
# GvCMqGJRRWcI4z88HpP4MIUXyDlAptcOsyEp5aWhaYwik8x0mOehR0PyU6zADzBp
# f/7SJSBtb2HT3wfV2XIALGmGdj1R26Y5SMk3YW0H3VMZy6fWYcK/4oOrD+Brm5XW
# fShRsIlKUaSabMi3H0oaDmmp19zBftFJcKq2rbtyR2MX+qbWoqaG7KgQRJtjtrJp
# iQbHRoZ6GD/oxR0h1Xv5AiMtxUHLvx1MyBbvsZx//CJLSYpuFeOmf3Zb0VN5kYWd
# 1dLbPXM18zyuVLJSR2rAqhOV0o4R2plnXjKM+zeF0dx1hZyHxlpXhcK/3Q2PjJst
# 67TuzyfTtV5p+qQWBAGnJGdzz01Ptt4FVpd69+lSTfR3BU+FxtgL8Y7tQgnRDXbj
# I1Z4IiY2vsqxjG6qHeSF2kczYo+kyZEzX3EeQK+YZcki6EIhJYocLWDZN4lBiSoW
# D9dhPJRoYFLv1keZoIBA7hWBdz6c4FMYGlAdOJWbHmYzEyc5F3iHNs5Ow1+y9T1H
# U7bg5dsLYT0q15IszjdaPkBCMaQfEAjCVpy/JF1RAp1qedIX09rBlI4HeyVxRKsG
# aubUxt8jmpZ1xTGCFdQwghXQAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcg
# UENBIDIwMTACEzMAAAAWEQS0iDiMvsMAAAAAABYwDQYJYIZIAWUDBAIBBQCggcIw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIP6WWXhP9Qtge+32B5KA09zM2UNpDUE
# zQwD7IHBwEozMFYGCisGAQQBgjcCAQwxSDBGoCyAKgBBAGQAZAAtAEEAcABwAEQA
# ZQB2AFAAYQBjAGsAYQBnAGUALgBwAHMAMaEWgBRodHRwOi8vbWljcm9zb2Z0LmNv
# bTANBgkqhkiG9w0BAQEFAASCAQBlTkjS31J0Jd/ntRLHnsFN2DsMm+yvJKCz9Nuc
# qLYni/0tsh1hED76XmxQvIGmPTwOjRAn1cYrTqQcjm9QYAzLnbKIyUNQIR7N4pr/
# ZaELbV1DRdwpnyXvp6TffD0u+xoboFVk2qCaSnyTNfsHIZ8Dwx+DgjY96ajVIYkO
# RYPjbCC3P9H8aNhon5FckZ1heUlc5zCbWC2rrryU/Wa+jKxaTWgehWfcBp4gxzz2
# vLu2wO8DQSGLdaL3e4K8hu4mVV4mobuVbyofzH1XdjtwmZjpHcWiGzuSJx+S8BtA
# 7jfzatVoBn8wi4E7LaEHPHx9SgOgNWxYLmmu/52AVBWsf7B+oYITSjCCE0YGCisG
# AQQBgjcDAwExghM2MIITMgYJKoZIhvcNAQcCoIITIzCCEx8CAQMxDzANBglghkgB
# ZQMEAgEFADCCAT0GCyqGSIb3DQEJEAEEoIIBLASCASgwggEkAgEBBgorBgEEAYRZ
# CgMBMDEwDQYJYIZIAWUDBAIBBQAEIHW+7JDjH8y6JEymXE+xUxMe8jnffgnrqyUI
# aJCvNU89AgZRt57Ie2AYEzIwMTMwNjE3MDM0MDA0LjU2MVowBwIBAYACAfSggbmk
# gbYwgbMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNV
# BAsTBE1PUFIxJzAlBgNVBAsTHm5DaXBoZXIgRFNFIEVTTjpDMEY0LTMwODYtREVG
# ODElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCDs0wggZx
# MIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQg
# Um9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0xMDA3MDEyMTM2NTVa
# Fw0yNTA3MDEyMTQ2NTVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIIB
# IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqR0NvHcRijog7PwTl/X6f2mU
# a3RUENWlCgCChfvtfGhLLF/Fw+Vhwna3PmYrW/AVUycEMR9BGxqVHc4JE458YTBZ
# sTBED/FgiIRUQwzXTbg4CLNC3ZOs1nMwVyaCo0UN0Or1R4HNvyRgMlhgRvJYR4Yy
# hB50YWeRX4FUsc+TTJLBxKZd0WETbijGGvmGgLvfYfxGwScdJGcSchohiq9LZIlQ
# YrFd/XcfPfBXday9ikJNQFHRD5wGPmd/9WbAA5ZEfu/QS/1u5ZrKsajyeioKMfDa
# TgaRtogINeh4HLDpmc085y9Euqf03GS9pAHBIAmTeM38vMDJRF1eFpwBBU8iTQID
# AQABo4IB5jCCAeIwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNVjOlyKMZDz
# Q3t8RhvFM2hahW1VMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQ
# W9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNv
# bS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBa
# BggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MIGgBgNV
# HSABAf8EgZUwgZIwgY8GCSsGAQQBgjcuAzCBgTA9BggrBgEFBQcCARYxaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL1BLSS9kb2NzL0NQUy9kZWZhdWx0Lmh0bTBABggr
# BgEFBQcCAjA0HjIgHQBMAGUAZwBhAGwAXwBQAG8AbABpAGMAeQBfAFMAdABhAHQA
# ZQBtAGUAbgB0AC4gHTANBgkqhkiG9w0BAQsFAAOCAgEAB+aIUQ3ixuCYP4FxAz2d
# o6Ehb7Prpsz1Mb7PBeKp/vpXbRkws8LFZslq3/Xn8Hi9x6ieJeP5vO1rVFcIK1GC
# RBL7uVOMzPRgEop2zEBAQZvcXBf/XPleFzWYJFZLdO9CEMivv3/Gf/I3fVo/HPKZ
# eUqRUgCvOA8X9S95gWXZqbVr5MfO9sp6AG9LMEQkIjzP7QOllo9ZKby2/QThcJ8y
# Sif9Va8v/rbljjO7Yl+a21dA6fHOmWaQjP9qYn/dxUoLkSbiOewZSnFjnXshbcOc
# o6I8+n99lmqQeKZt0uGc+R38ONiU9MalCpaGpL2eGq4EQoO4tYCbIjggtSXlZOz3
# 9L9+Y1klD3ouOVd2onGqBooPiRa6YacRy5rYDkeagMXQzafQ732D8OE7cQnfXXSY
# Ighh2rBQHm+98eEA3+cxB6STOvdlR3jo+KhIq/fecn5ha293qYHLpwmsObvsxsvY
# grRyzR30uIUBHoD7G4kqVDmyW9rIDVWZeodzOwjmmC3qjeAzLhIp9cAvVCch98is
# TtoouLGp25ayp0Kiyc8ZQU3ghvkqmqMRZjDTu3QyS99je/WZii8bxyGvWbWu3EQ8
# l1Bx16HSxVXjad5XwdHeMMD9zOZN+w2/XU/pnR4ZOC+8z1gFLu8NoFA12u8JJxzV
# s341Hgi62jbb01+P3nSISRIwggTaMIIDwqADAgECAhMzAAAAKJBnuQSwPG5mAAAA
# AAAoMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# MB4XDTEzMDMyNzIwMTMxM1oXDTE0MDYyNzIwMTMxM1owgbMxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNVBAsTBE1PUFIxJzAlBgNVBAsT
# Hm5DaXBoZXIgRFNFIEVTTjpDMEY0LTMwODYtREVGODElMCMGA1UEAxMcTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
# AQoCggEBAN2lSL9qSJ1KIZySa97gLdzkY/jMuYnExxu957XT++2uzzH+82awRAPa
# mWcIWr91BiIRidBnUsz6z5I3Rej68b0z08xz47ghpKAVfcsvxAMF2j+Wc9NZ5ZhN
# C1aGL51H0dZfnZHpx4TZlWsyTLRrAFLgQdM8aXSozsx9aJ1SVeZwfxQHop5nsIZE
# 8zM/c13GKPgXX1IBLUQv1u14CLjlOy/AucNLw7c7L9OmtZyxSErdMglWoRtLWtOq
# JicMEkNgxWrX2kANYJiJQbuTc92//sSMW876VSfKTU2ab30RbLFHI7BMfGx/BqF0
# gh9SeBjpBhoWUJrDOt2BgfebJ3Ihf3UCAwEAAaOCARswggEXMB0GA1UdDgQWBBTc
# mAidedEEsotHw3HQjOez5rBTnTAfBgNVHSMEGDAWgBTVYzpcijGQ80N7fEYbxTNo
# WoVtVTBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNUaW1TdGFQQ0FfMjAxMC0wNy0wMS5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAxLmNydDAMBgNVHRMB
# Af8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3DQEBCwUAA4IBAQCC
# IvO3PWR+Ekv8Jvzg5LfQxBROCf6rVprRWpimvoxBHpS0Mr6EtLdFduPvYBgkh6jP
# 6bTRVCm8yuTLEnvA8dQOnzEzGxE/ejvd3QKqGMrKPPqW42y7r7vJhD7H2AyFy3IL
# ARuk9TEREAxFpVpImX7avkWG17pN5IH/01gKdmUGWS/2wkLPBMmrG/phnfXzmElw
# sUnQZMQh6O5gF1N+6wLaaJWL9Qo8AdujtZgUUXSeU+nacphmoF8pz4+vH4Kc0+vm
# 8UwbVPjoMtzBFcOsKm50BRaD40SYn8vv6DB5f69SpTof32XHjf4n2EcZkgi0izSO
# aSc3GgL2kbOVIv8ISCr+oYIDdjCCAl4CAQEwgeOhgbmkgbYwgbMxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDTALBgNVBAsTBE1PUFIxJzAlBgNV
# BAsTHm5DaXBoZXIgRFNFIEVTTjpDMEY0LTMwODYtREVGODElMCMGA1UEAxMcTWlj
# cm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIlCgEBMAkGBSsOAwIaBQADFQDzXbQe
# x187Zk5lDt6YBFP2FacfRKCBwjCBv6SBvDCBuTELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjENMAsGA1UECxMETU9QUjEnMCUGA1UECxMebkNpcGhl
# ciBOVFMgRVNOOkIwMjctQzZGOC0xRDg4MSswKQYDVQQDEyJNaWNyb3NvZnQgVGlt
# ZSBTb3VyY2UgTWFzdGVyIENsb2NrMA0GCSqGSIb3DQEBBQUAAgUA1WjKOTAiGA8y
# MDEzMDYxNjIzMzUyMVoYDzIwMTMwNjE3MjMzNTIxWjB0MDoGCisGAQQBhFkKBAEx
# LDAqMAoCBQDVaMo5AgEAMAcCAQACAh7xMAcCAQACAhfxMAoCBQDVahu5AgEAMDYG
# CisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwGgCjAIAgEAAgMW42ChCjAIAgEA
# AgMHoSAwDQYJKoZIhvcNAQEFBQADggEBAMHqt9hrTLcHoO52a4queCa3QS9sjmwf
# qvkR1jlSYiVIXsa1rxKM4G76qH84TKS4S/MpnyR5rxfA5+IiJfuYuUDoJAMLGw/n
# A+on0Y09kuluNGw+Jnxioh9epxWz88zsocUrjtvDYDyZxQW1p4Mu29/BLaIIZ8LQ
# hqGjL5An9S45Ob3ZxssQSkgdXRHFSFZKTzghJsCr8uvMVnK65qrh1AYa+jVfg+ow
# HlnLjt6HwOV9YGCsYy1LshXR8chtvd+muaqoOOe1WRyqwckVkBuPzn3HUXUVTRkY
# R+SAUiwe8A8QR6x7kK6+7sTLx9S9HAFvKwGp2jbAeAATcyuXaJQTQHMxggL1MIIC
# 8QIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYw
# JAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAACiQZ7kE
# sDxuZgAAAAAAKDANBglghkgBZQMEAgEFAKCCATIwGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCC1Ll21KCZd545DLCifrGNtXS/4J/Zy
# 4EgEN6HfqHZ8YTCB4gYLKoZIhvcNAQkQAgwxgdIwgc8wgcwwgbEEFPNdtB7HXztm
# TmUO3pgEU/YVpx9EMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAAokGe5BLA8bmYAAAAAACgwFgQUXj6gmZdXCjf7waJEUjBt3LoLWRww
# DQYJKoZIhvcNAQELBQAEggEAKLJ4I54gCY881tYRevT+XZ2rFJOoddLVqoUZZ/uQ
# qoeuysSUGdDUoNqWQtbuPtkQN+iABprRvyTXroH3cNW3d4+7W0Im9zCwbK5QwCD6
# khxiZhqygEaDrprDG1U/In4tobVw5+TtTVKOjID1g/j2/p6fc11SuDLDZPEdEBod
# ew5HVyZMJwRyhQti1pnOIZWewU3liHdtoMX6fWqCsb8OnN9mkv/hgdVGn4pOzcu6
# FQujfbtV3itnPOdySi6Yb/hOOlC9sj3NGQw3lhFiUy12BFXSm6KpoU5rMfm8O1Zt
# Cha/t5u5/yd6jkLe3jV2at5u9GjhLq7l/O0THM7OCh09qw==
# SIG # End signature block

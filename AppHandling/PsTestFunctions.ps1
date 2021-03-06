﻿Param(
    [Parameter(Mandatory=$true)]
    [string] $clientDllPath,
    [Parameter(Mandatory=$true)]
    [string] $newtonSoftDllPath,
    [string] $clientContextScriptPath = $null
)

# Load DLL's
Add-type -Path $clientDllPath
Add-type -Path $newtonSoftDllPath

if (!($clientContextScriptPath)) {
    $clientContextScriptPath = Join-Path $PSScriptRoot "ClientContext.ps1"
}

. $clientContextScriptPath

function New-ClientContext {
    Param(
        [Parameter(Mandatory=$true)]
        [string] $serviceUrl,
        [ValidateSet('Windows','NavUserPassword','AAD')]
        [string] $auth='NavUserPassword',
        [Parameter(Mandatory=$false)]
        [pscredential] $credential,
        [timespan] $interactionTimeout = [timespan]::FromMinutes(10),
        [string] $culture = "en-US",
        [string] $timezone = "",
        [switch] $debugMode
    )

    if ($auth -eq "Windows") {
        $clientContext = [ClientContext]::new($serviceUrl, $interactionTimeout, $culture, $timezone)
    }
    elseif ($auth -eq "NavUserPassword") {
        if ($Credential -eq $null -or $credential -eq [System.Management.Automation.PSCredential]::Empty) {
            throw "You need to specify credentials if using NavUserPassword authentication"
        }
        $clientContext = [ClientContext]::new($serviceUrl, $credential, $interactionTimeout, $culture, $timezone)
    }
    elseif ($auth -eq "AAD") {

        if ($Credential -eq $null -or $credential -eq [System.Management.Automation.PSCredential]::Empty) {
            throw "You need to specify credentials (Username and AccessToken) if using AAD authentication"
        }
        $accessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password))
        $clientContext = [ClientContext]::new($serviceUrl, $accessToken, $interactionTimeout, $culture, $timezone)
    }
    else {
        throw "Unsupported authentication setting"
    }
    if ($clientContext) {
        $clientContext.debugMode = $debugMode
    }
    return $clientContext
}

function Remove-ClientContext {
    Param(
        [ClientContext] $clientContext
    )
    if ($clientContext) {
        $clientContext.Dispose()
    }
}

function Dump-ClientContext {
    Param(
        [ClientContext] $clientContext
    )
    if ($clientContext) {
        $clientContext.GetAllForms() | % {
            $formInfo = $clientContext.GetFormInfo($_)
            if ($formInfo) {
                Write-Host -ForegroundColor Yellow "Title: $($formInfo.title)"
                Write-Host -ForegroundColor Yellow "Title: $($formInfo.identifier)"
                $formInfo.controls | ConvertTo-Json -Depth 99 | Out-Host
            }
        }
    }
}

function Set-ExtensionId
(
    [string] $ExtensionId,
    [ClientContext] $ClientContext,
    [switch] $debugMode,
    $Form
)
{
    if(!$ExtensionId)
    {
        return
    }
    
    if ($debugMode) {
        Write-Host "Setting Extension Id $ExtensionId"
    }
    $extensionIdControl = $ClientContext.GetControlByName($Form, "ExtensionId")
    $ClientContext.SaveValue($extensionIdControl, $ExtensionId)
}

function Set-RunFalseOnDisabledTests
(
    [ClientContext] $ClientContext,
    [array] $DisabledTests,
    [switch] $debugMode,
    $Form
)
{
    if(!$DisabledTests)
    {
        return
    }

    $removeTestMethodControl = $ClientContext.GetControlByName($Form, "DisableTestMethod")
    foreach($disabledTestMethod in $DisabledTests)
    {
        if ($debugMode) {
            Write-Host "Disabling Test $($disabledTestMethod.codeunitName):$($disabledTestMethod.method)"
        }
        $testKey = $disabledTestMethod.codeunitName + "," + $disabledTestMethod.method
        $ClientContext.SaveValue($removeTestMethodControl, $testKey)
    }
}

function Get-Tests {
    Param(
        [ClientContext] $clientContext,
        [int] $testPage = 130409,
        [string] $testSuite = "DEFAULT",
        [string] $testCodeunit = "*",
        [string] $extensionId = "",
        [array]  $disabledtests = @(),
        [switch] $debugMode,
        [switch] $ignoreGroups
    )

    if ($testPage -eq 130455) {
        $LineTypeAdjust = 1
    }
    else {
        $lineTypeAdjust = 0
        if ($disabledTests) {
            throw "Specifying disabledTests is not supported when using the C/AL test runner"
        }
        if ($extensionId) {
            throw "Specifying extensionId is not supported when using the C/AL test runner"
        }
    }

    if ($debugMode) {
        Write-Host "Get-Tests, open page $testpage"
    }

    $form = $clientContext.OpenForm($testPage)
    if (!($form)) {
        throw "Cannot open page $testPage. You might need to import the test toolkit to the container and/or remove the folder $PSScriptRoot and retry. You might also have URL or Company name wrong."
    }

    $suiteControl = $clientContext.GetControlByName($form, "CurrentSuiteName")
    $clientContext.SaveValue($suiteControl, $testSuite)

    if ($testPage -eq 130455) {
        Set-ExtensionId -ExtensionId $extensionId -Form $form -ClientContext $clientContext -debugMode:$debugMode
        Set-RunFalseOnDisabledTests -DisabledTests $DisabledTests -Form $form -ClientContext $clientContext -debugMode:$debugMode
        $clientContext.InvokeAction($clientContext.GetActionByName($form, 'ClearTestResults'))
    }

    $repeater = $clientContext.GetControlByType($form, [ClientRepeaterControl])
    $index = 0
    if ($testPage -eq 130455) {
        if ($debugMode) {
            Write-Host "Offset: $($repeater.offset)"
        }
        $clientContext.SelectFirstRow($repeater)
        $clientContext.Refresh($repeater)
        if ($debugMode) {
            Write-Host "Offset: $($repeater.offset)"
        }
    }

    $Tests = @()
    $group = $null
    while ($true)
    {
        if ($debugMode) {
            Write-Host "Index:  $index, Offset: $($repeater.Offset), Count:  $($repeater.DefaultViewport.Count)"
        }        
        if ($index -ge ($repeater.Offset + $repeater.DefaultViewport.Count))
        {
            if ($debugMode) {
                Write-Host "Scroll"
            }
            $clientContext.ScrollRepeater($repeater, 1)
            if ($debugMode) {
                Write-Host "Index:  $index, Offset: $($repeater.Offset), Count:  $($repeater.DefaultViewport.Count)"
            }        
        }
        $rowIndex = $index - $repeater.Offset
        $index++
        if ($rowIndex -ge $repeater.DefaultViewport.Count)
        {
            if ($debugMode) {
                Write-Host "Breaking - rowIndex: $rowIndex"
            }
            break 
        }
        $row = $repeater.DefaultViewport[$rowIndex]
        $lineTypeControl = $clientContext.GetControlByName($row, "LineType")
        $lineType = "$(([int]$lineTypeControl.StringValue) + $lineTypeAdjust)"
        $name = $clientContext.GetControlByName($row, "Name").StringValue
        $codeUnitId = $clientContext.GetControlByName($row, "TestCodeunit").StringValue
        if ($testPage -eq 130455) {
            $run = $clientContext.GetControlByName($row, "Run").StringValue
        }
        else{
            $run = $true
        }

        if ($debugMode) {
            Write-Host "Row - lineType = $linetype, run = $run, CodeunitId = $codeUnitId, codeunitName = '$codeunitName', name = '$name'"
        }

        if ($name) {
            if ($linetype -eq "0" -and !$ignoreGroups) {
                $group = @{ "Group" = $name; "Codeunits" = @() }
                $Tests += $group
                            
            } elseif ($linetype -eq "1") {
                $codeUnitName = $name
                if ($codeunitId -like $testCodeunit -or $codeunitName -like $testCodeunit) {
                    if ($debugMode) { 
                        Write-Host "Initialize Codeunit"
                    }
                    $codeunit = @{ "Id" = "$codeunitId"; "Name" = $codeUnitName; "Tests" = @() }
                    if ($group) {
                        $group.Codeunits += $codeunit
                    }
                    else {
                        if ($run) {
                            if ($debugMode) { 
                                Write-Host "Add codeunit to tests"
                            }
                            $Tests += $codeunit
                        }
                    }
                }
            } elseif ($lineType -eq "2") {
                if ($codeunitId -like $testCodeunit -or $codeunitName -like $testCodeunit) {
                    if ($run) {
                        if ($debugMode) { 
                            Write-Host "Add test $name"
                        }
                        $codeunit.Tests += $name
                    }
                }
            }
        }
    }
    $clientContext.CloseForm($form)
    $Tests | ConvertTo-Json
}

function Run-Tests {
    Param(
        [ClientContext] $clientContext,
        [int] $testPage = 130409,
        [string] $testSuite = "DEFAULT",
        [string] $testCodeunit = "*",
        [string] $testGroup = "*",
        [string] $testFunction = "*",
        [string] $extensionId = "",
        [array]  $disabledtests = @(),
        [switch] $detailed,
        [switch] $debugMode,
        [string] $XUnitResultFileName = "",
        [switch] $AppendToXUnitResultFile,
        [switch] $ReRun,
        [ValidateSet('no','error','warning')]
        [string] $AzureDevOps = 'no'
    )

    if ($testPage -eq 130455) {
        $LineTypeAdjust = 1
        $runSelectedName = "RunSelectedTests"
        $callStackName = "Stack Trace"
        $firstErrorName = "Error Message"
    }
    else {
        $lineTypeAdjust = 0
        $runSelectedName = "RunSelected"
        $callStackName = "Call Stack"
        $firstErrorName = "First Error"
        if ($disabledTests) {
            throw "Specifying disabledTests is not supported when using the C/AL test runner"
        }
        if ($extensionId) {
            throw "Specifying extensionId is not supported when using the C/AL test runner"
        }
    }
    $allPassed = $true

    if ($debugMode) {
        Write-Host "Run-Tests, open page $testpage"
    }

    $form = $clientContext.OpenForm($testPage)
    if (!($form)) {
        throw "Cannot open page $testPage. You might need to import the test toolkit to the container and/or remove the folder $PSScriptRoot and retry. You might also have URL or Company name wrong."
    }

    $suiteControl = $clientContext.GetControlByName($form, "CurrentSuiteName")
    $clientContext.SaveValue($suiteControl, $testSuite)

    if ($testPage -eq 130455) {
        Set-ExtensionId -ExtensionId $extensionId -Form $form -ClientContext $clientContext -debugMode:$debugMode
        Set-RunFalseOnDisabledTests -DisabledTests $DisabledTests -Form $form -ClientContext $clientContext -debugMode:$debugMode
        $clientContext.InvokeAction($clientContext.GetActionByName($form, 'ClearTestResults'))
    }

    if ($XUnitResultFileName) {
        if (($Rerun -or $AppendToXUnitResultFile) -and (Test-Path $XUnitResultFileName)) {
            [xml]$XUnitDoc = Get-Content $XUnitResultFileName
            $XUnitAssemblies = $XUnitDoc.assemblies
            if (-not $XUnitAssemblies) {
                [xml]$XUnitDoc = New-Object System.Xml.XmlDocument
                $XUnitDoc.AppendChild($XUnitDoc.CreateXmlDeclaration("1.0","UTF-8",$null)) | Out-Null
                $XUnitAssemblies = $XUnitDoc.CreateElement("assemblies")
                $XUnitDoc.AppendChild($XUnitAssemblies) | Out-Null
            }
        }
        else {
            if (Test-Path $XUnitResultFileName -PathType Leaf) {
                Remove-Item $XUnitResultFileName -Force
            }
            [xml]$XUnitDoc = New-Object System.Xml.XmlDocument
            $XUnitDoc.AppendChild($XUnitDoc.CreateXmlDeclaration("1.0","UTF-8",$null)) | Out-Null
            $XUnitAssemblies = $XUnitDoc.CreateElement("assemblies")
            $XUnitDoc.AppendChild($XUnitAssemblies) | Out-Null
        }
    }

    if ($testPage -eq 130455 -and $testCodeunit -eq "*" -and $testFunction -eq "*" -and $testGroup -eq "*" -and "$extensionId" -ne "") {

        if ($debugMode) {
            Write-Host "Using new test-runner mechanism"
        }

        while ($true) {
        
            $validationResults = $form.validationResults
            if ($validationResults) {
                throw "Validation errors occured. Error is: $($validationResults | ConvertTo-Json -Depth 99)"
            }
        
            if ($debugMode) {
                Write-Host "Invoke RunNextTest"
            }
            $clientContext.InvokeAction($clientContext.GetActionByName($form, "RunNextTest"))
            $testResultControl = $clientContext.GetControlByName($form, "TestResultJson")
            $testResultJson = $testResultControl.StringValue

            if ($debugMode) {
                Write-Host "Result: '$testResultJson'"
            }

            if ($testResultJson -eq 'All tests executed.' -or $testResultJson -eq '') {
                break
            }
            $result = $testResultJson | ConvertFrom-Json
        
            Write-Host -NoNewline "  Codeunit $($result.codeUnit) $($result.name) "

            if ($ReRun) {
                $LastResult = $XUnitDoc.assemblies.ChildNodes | Where-Object { $_.name -eq "$($result.codeUnit) $($result.name)" }
                if ($LastResult) {
                    $XUnitDoc.assemblies.RemoveChild($LastResult) | Out-Null
                }
            }
        
            $XUnitAssembly = $XUnitDoc.CreateElement("assembly")
            $XUnitAssembly.SetAttribute("name","$($result.codeUnit) $($result.name)")
            $XUnitAssembly.SetAttribute("test-framework", "PS Test Runner")
            $XUnitAssembly.SetAttribute("run-date", [DateTime]::Parse($result.startTime).ToString("yyyy-MM-dd"))
            $XUnitAssembly.SetAttribute("run-time", [DateTime]::Parse($result.startTime).ToString("HH:mm:ss"))
            $XUnitAssembly.SetAttribute("total", $result.testResults.Count)
            $XUnitCollection = $XUnitDoc.CreateElement("collection")
            $XUnitAssembly.AppendChild($XUnitCollection) | Out-Null
            $XUnitCollection.SetAttribute("name", $result.name)
            $XUnitCollection.SetAttribute("total", $result.testResults.Count)
        
            $totalduration = [Timespan]::Zero
            $result.testResults | % {
                $testduration = [DateTime]::Parse($_.finishTime).Subtract([DateTime]::Parse($_.startTime))
                $totalduration += $testduration
            }
        
            if ($result.result -eq "2") {
                Write-Host -ForegroundColor Green "Success ($([Math]::Round($totalduration.TotalSeconds,3)) seconds)"
            }
            elseif ($result.result -eq "1") {
                Write-Host -ForegroundColor Red "Failure ($([Math]::Round($totalduration.TotalSeconds,3)) seconds)"
                $allPassed = $false
            }
            else {
                Write-Host -ForegroundColor Yellow "Skipped"
            }
        
            $passed = 0
            $failed = 0
            $skipped = 0
        
            $result.testResults | % {
        
                $testduration = [DateTime]::Parse($_.finishTime).Subtract([DateTime]::Parse($_.startTime))
        
                if ($XUnitAssembly.ParentNode -eq $null) {
                    $XUnitAssemblies.AppendChild($XUnitAssembly) | Out-Null
                }
        
                $XUnitTest = $XUnitDoc.CreateElement("test")
                $XUnitCollection.AppendChild($XUnitTest) | Out-Null
                $XUnitTest.SetAttribute("name", $XUnitCollection.GetAttribute("name")+':'+$_.method)
                $XUnitTest.SetAttribute("method", $_.method)
                $XUnitTest.SetAttribute("time", [Math]::Round($testduration.TotalSeconds,3).ToString([System.Globalization.CultureInfo]::InvariantCulture))
                if ($_.result -eq 2) {
                    if ($detailed) {
                        Write-Host -ForegroundColor Green "    Testfunction $($_.method) Success ($([Math]::Round($testduration.TotalSeconds,3)) seconds)"
                    }
                    $XUnitTest.SetAttribute("result", "Pass")
                    $passed++
                }
                elseif ($_.result -eq 1) {
                    if ($AzureDevOps -ne 'no') {
                        Write-Host "##vso[task.logissue type=$AzureDevOps;sourcepath=$($_.method);]$($_.message)"
                    }
                    Write-Host -ForegroundColor Red "    Testfunction $($_.method) Failure ($([Math]::Round($testduration.TotalSeconds,3)) seconds)"
                    $XUnitTest.SetAttribute("result", "Fail")
                    $failed++
        
                    if ($detailed) {
                        $stacktrace = $_.stacktrace
                        if ($stacktrace.EndsWith(';')) {
                            $stacktrace = $stacktrace.Substring(0,$stacktrace.Length-1)
                        }
                        Write-Host -ForegroundColor Red "      Error:"
                        Write-Host -ForegroundColor Red "        $($_.message)"
                        Write-Host -ForegroundColor Red "      Call Stack:"
                        Write-Host -ForegroundColor Red "        $($stacktrace.Replace(";","`n        "))"
                    }
        
                    $XUnitFailure = $XUnitDoc.CreateElement("failure")
                    $XUnitMessage = $XUnitDoc.CreateElement("message")
                    $XUnitMessage.InnerText = $_.message
                    $XUnitFailure.AppendChild($XUnitMessage) | Out-Null
                    $XUnitStacktrace = $XUnitDoc.CreateElement("stack-trace")
                    $XUnitStacktrace.InnerText = $_.stacktrace.Replace(";","`n")
                    $XUnitFailure.AppendChild($XUnitStacktrace) | Out-Null
                    $XUnitTest.AppendChild($XUnitFailure) | Out-Null
                }
                else {
                    if ($detailed) {
                        Write-Host -ForegroundColor Yellow "    Testfunction $($_.method) Skipped"
                    }
        
                    $XUnitTest.SetAttribute("result", "Skip")
                    $skipped++
                }
            }
        
            $XUnitAssembly.SetAttribute("passed", $Passed)
            $XUnitAssembly.SetAttribute("failed", $failed)
            $XUnitAssembly.SetAttribute("skipped", $skipped)
            $XUnitAssembly.SetAttribute("time", [Math]::Round($totalduration.TotalSeconds,3).ToString([System.Globalization.CultureInfo]::InvariantCulture))
        
            $XUnitCollection.SetAttribute("passed", $Passed)
            $XUnitCollection.SetAttribute("failed", $failed)
            $XUnitCollection.SetAttribute("skipped", $skipped)
            $XUnitCollection.SetAttribute("time", [Math]::Round($totalduration.TotalSeconds,3).ToString([System.Globalization.CultureInfo]::InvariantCulture))
        }

    }
    else {

        if ($debugMode -and $testpage -eq 130455) {
            Write-Host "Using repeater based test-runner"
        }
        
        $filterControl = $clientContext.GetControlByType($form, [ClientFilterLogicalControl])
        $repeater = $clientContext.GetControlByType($form, [ClientRepeaterControl])
        $index = 0
        if ($testPage -eq 130455) {
            if ($debugMode) {
                Write-Host "Offset: $($repeater.offset)"
            }
            $clientContext.SelectFirstRow($repeater)
            $clientContext.Refresh($repeater)
            if ($debugMode) {
                Write-Host "Offset: $($repeater.offset)"
            }
        }

        $i = 0
        if ([int]::TryParse($testCodeunit, [ref] $i) -and ($testCodeunit -eq $i)) {
            if (([System.Management.Automation.PSTypeName]'Microsoft.Dynamics.Framework.UI.Client.Interactions.ExecuteFilterInteraction').Type) {
                $filterInteraction = New-Object Microsoft.Dynamics.Framework.UI.Client.Interactions.ExecuteFilterInteraction -ArgumentList $filterControl
                $filterInteraction.QuickFilterColumnId = $filterControl.QuickFilterColumns[0].Id
                $filterInteraction.QuickFilterValue = $testCodeunit
                $clientContext.InvokeInteraction($filterInteraction)
            }
            else {
                $filterInteraction = New-Object Microsoft.Dynamics.Framework.UI.Client.Interactions.FilterInteraction -ArgumentList $filterControl
                $filterInteraction.FilterColumnId = $filterControl.FilterColumns[0].Id
                $filterInteraction.FilterValue = $testCodeunit
                $clientContext.InvokeInteraction($filterInteraction)
            }
        }
    
        $codeunitName = ""
        $codeunitNames = @{}
        $LastCodeunitName = ""
        $groupName = ""
    
        while ($true)
        {
    
            $validationResults = $form.validationResults
            if ($validationResults) {
                throw "Validation errors occured. Error is: $($validationResults | ConvertTo-Json -Depth 99)"
            }
    
            do {
    
                if ($debugMode) {
                    Write-Host "Index:  $index, Offset: $($repeater.Offset), Count:  $($repeater.DefaultViewport.Count)"
                }        
    
                if ($index -ge ($repeater.Offset + $repeater.DefaultViewport.Count))
                {
                    if ($debugMode) {
                        Write-Host "Scroll"
                    }
                    $clientContext.ScrollRepeater($repeater, 1)
                    if ($debugMode) {
                        Write-Host "Index:  $index, Offset: $($repeater.Offset), Count:  $($repeater.DefaultViewport.Count)"
                    }        
                }
                $rowIndex = $index - $repeater.Offset
                $index++
                if ($rowIndex -ge $repeater.DefaultViewport.Count)
                {
                    if ($debugMode) {
                        Write-Host "Breaking - rowIndex: $rowIndex"
                    }
                    break
                }
                $row = $repeater.DefaultViewport[$rowIndex]
                $lineTypeControl = $clientContext.GetControlByName($row, "LineType")
                $lineType = "$(([int]$lineTypeControl.StringValue) + $lineTypeAdjust)"
                $name = $clientContext.GetControlByName($row, "Name").StringValue
                $codeUnitId = $clientContext.GetControlByName($row, "TestCodeunit").StringValue
                if ($testPage -eq 130455) {
                    $run = $clientContext.GetControlByName($row, "Run").StringValue
                }
                else{
                    $run = $true
                }

                if ($debugMode) {
                    Write-Host "Row - lineType = $linetype, run = $run, CodeunitId = $codeUnitId, codeunitName = '$codeunitName', name = '$name'"
                }
    
                if ($name) {
                    if ($linetype -eq "0") {
                        $groupName = $name
                    }
                    elseif ($linetype -eq "1") {
                        $codeUnitName = $name
                        if (!($codeUnitNames.Contains($codeunitId))) {
                            $codeUnitNames += @{ $codeunitId = $codeunitName }
                        }
                    }
                    elseif ($linetype -eq "2") {
                        $codeUnitname = $codeUnitNames[$codeunitId]
                    }
                }
            } while (!(($codeunitId -like $testCodeunit -or $codeunitName -like $testCodeunit) -and ($linetype -eq "1" -or $name -like $testFunction)))
    
            if ($debugMode) {
                Write-Host "Found Row - index = $index, rowIndex = $($rowIndex)/$($repeater.DefaultViewport.Count), lineType = $linetype, run = $run, CodeunitId = $codeUnitId, codeunitName = '$codeunitName', name = '$name'"
            }
    
            if ($rowIndex -ge $repeater.DefaultViewport.Count -or !($name))
            {
                break 
            }
    
            if ($groupName -like $testGroup) {
                switch ($linetype) {
                    "1" {
                        $startTime = get-date
                        $totalduration = [Timespan]::Zero

                        if ($TestFunction -eq "*") {
                            Write-Host "  Codeunit $codeunitId $name " -NoNewline

                            $prevoffset = $repeater.Offset

                            if ($testPage -eq 130455) {
                                $filterInteraction = New-Object Microsoft.Dynamics.Framework.UI.Client.Interactions.FilterInteraction -ArgumentList $filterControl
                                $filterInteraction.FilterColumnId = $filterControl.FilterColumns[0].Id
                                $filterInteraction.FilterValue = $codeUnitId
                                $clientContext.InvokeInteraction($filterInteraction)
                                $clientContext.SelectFirstRow($repeater)
                                #$clientContext.Refresh($repeater)
                            }
                            else {
                                $clientContext.ActivateControl($lineTypeControl)
                            }

                            $clientContext.InvokeAction($clientContext.GetActionByName($form, $runSelectedName))
            
                            if ($testPage -eq 130455) {
                                $filterInteraction = New-Object Microsoft.Dynamics.Framework.UI.Client.Interactions.FilterInteraction -ArgumentList $filterControl
                                $filterInteraction.FilterColumnId = $filterControl.FilterColumns[0].Id
                                $filterInteraction.FilterValue = ''
                                $clientContext.InvokeInteraction($filterInteraction)
                                $clientContext.SelectFirstRow($repeater)
                                #$clientContext.Refresh($repeater)
                            
                                while ($repeater.Offset -lt $prevoffset) {
                                    $clientContext.ScrollRepeater($repeater, 1)
                                }
                                $row = $repeater.DefaultViewport[$rowIndex]
                            }
                            else {
                                $row = $repeater.CurrentRow
                                if ($repeater.DefaultViewport[0].Bookmark -eq $row.Bookmark) {
                                    $index = $repeater.Offset+1
                                }
                            }

                            $finishTime = get-date
                            $duration = $finishTime.Subtract($startTime)
    
                            $result = $clientContext.GetControlByName($row, "Result").StringValue
                            if ($result -eq "2") {
                                Write-Host -ForegroundColor Green "Success ($([Math]::Round($duration.TotalSeconds,3)) seconds)"
                            }
                            elseif ($result -eq "3") {
                                Write-Host -ForegroundColor Yellow "Skipped"
                            }
                            else {
                                Write-Host -ForegroundColor Red "Failure ($([Math]::Round($duration.TotalSeconds,3)) seconds)"
                                $allPassed = $false
                            }
                        }
                        if ($XUnitResultFileName) {
                            if ($ReRun) {
                                $LastResult = $XUnitDoc.assemblies.ChildNodes | Where-Object { $_.name -eq "$codeunitId $Name" }
                                if ($LastResult) {
                                    $XUnitDoc.assemblies.RemoveChild($LastResult) | Out-Null
                                }
                            }
                            $XUnitAssembly = $XUnitDoc.CreateElement("assembly")
                            $XUnitAssembly.SetAttribute("name","$codeunitId $Name")
                            $XUnitAssembly.SetAttribute("test-framework", "PS Test Runner")
                            $XUnitAssembly.SetAttribute("run-date", $startTime.ToString("yyyy-MM-dd"))
                            $XUnitAssembly.SetAttribute("run-time", $startTime.ToString("HH:mm:ss"))
                            $XUnitAssembly.SetAttribute("total",0)
                            $XUnitAssembly.SetAttribute("passed",0)
                            $XUnitAssembly.SetAttribute("failed",0)
                            $XUnitAssembly.SetAttribute("skipped",0)
                            $XUnitAssembly.SetAttribute("time", "0")
                            $XUnitCollection = $XUnitDoc.CreateElement("collection")
                            $XUnitAssembly.AppendChild($XUnitCollection) | Out-Null
                            $XUnitCollection.SetAttribute("name","$Name")
                            $XUnitCollection.SetAttribute("total",0)
                            $XUnitCollection.SetAttribute("passed",0)
                            $XUnitCollection.SetAttribute("failed",0)
                            $XUnitCollection.SetAttribute("skipped",0)
                            $XUnitCollection.SetAttribute("time", "0")
                        }
                    }
                    "2" {
                        if ($testFunction -ne "*") {
                            if ($LastCodeunitName -ne $codeunitName) {
                                Write-Host "Codeunit $CodeunitId $CodeunitName"
                                $LastCodeunitName = $CodeUnitname
                            }
                            $clientContext.ActivateControl($lineTypeControl)

                            $startTime = get-date
                            $clientContext.InvokeAction($clientContext.GetActionByName($form, $runSelectedName))
                            $finishTime = get-date
                            $testduration = $finishTime.Subtract($startTime)

                            $row = $repeater.CurrentRow
                            for ($idx = 0; $idx -lt $repeater.DefaultViewPort.Count; $idx++) {
                                if ($repeater.DefaultViewPort[$idx].Bookmark -eq $row.Bookmark) {
                                    $index = $repeater.Offset+$idx+1
                                }
                            }
                        }
                        $result = $clientContext.GetControlByName($row, "Result").StringValue
                        $startTime = $clientContext.GetControlByName($row, "Start Time").ObjectValue
                        $finishTime = $clientContext.GetControlByName($row, "Finish Time").ObjectValue
                        $testduration = $finishTime.Subtract($startTime)
                        $totalduration += $testduration
                        if ($XUnitResultFileName) {
                            if ($XUnitAssembly.ParentNode -eq $null) {
                                $XUnitAssemblies.AppendChild($XUnitAssembly) | Out-Null
                            }
                            $XUnitAssembly.SetAttribute("time",([Math]::Round($totalduration.TotalSeconds,3)).ToString([System.Globalization.CultureInfo]::InvariantCulture))
                            $XUnitAssembly.SetAttribute("total",([int]$XUnitAssembly.GetAttribute("total")+1))
                            $XUnitTest = $XUnitDoc.CreateElement("test")
                            $XUnitCollection.AppendChild($XUnitTest) | Out-Null
                            $XUnitTest.SetAttribute("name", $XUnitCollection.GetAttribute("name")+':'+$Name)
                            $XUnitTest.SetAttribute("method", $Name)
                            $XUnitTest.SetAttribute("time", ([Math]::Round($testduration.TotalSeconds,3)).ToString([System.Globalization.CultureInfo]::InvariantCulture))
                        }
                        if ($result -eq "2") {
                            if ($detailed) {
                                Write-Host -ForegroundColor Green "    Testfunction $name Success ($([Math]::Round($testduration.TotalSeconds,3)) seconds)"
                            }
                            if ($XUnitResultFileName) {
                                $XUnitAssembly.SetAttribute("passed",([int]$XUnitAssembly.GetAttribute("passed")+1))
                                $XUnitTest.SetAttribute("result", "Pass")
                            }
                        }
                        elseif ($result -eq "1") {
                            $firstError = $clientContext.GetControlByName($row, $firstErrorName).StringValue
                            if ($AzureDevOps -ne 'no') {
                                Write-Host "##vso[task.logissue type=$AzureDevOps;sourcepath=$name;]$firstError"
                            }
                            Write-Host -ForegroundColor Red "    Testfunction $name Failure ($([Math]::Round($testduration.TotalSeconds,3)) seconds)"
                            $allPassed = $false
                            $callStack = $clientContext.GetControlByName($row, $callStackName).StringValue
                            if ($callStack.EndsWith("\")) { $callStack = $callStack.Substring(0,$callStack.Length-1) }
                            if ($XUnitResultFileName) {
                                $XUnitAssembly.SetAttribute("failed",([int]$XUnitAssembly.GetAttribute("failed")+1))
                                $XUnitTest.SetAttribute("result", "Fail")
                                $XUnitFailure = $XUnitDoc.CreateElement("failure")
                                $XUnitMessage = $XUnitDoc.CreateElement("message")
                                $XUnitMessage.InnerText = $firstError
                                $XUnitFailure.AppendChild($XUnitMessage) | Out-Null
                                $XUnitStacktrace = $XUnitDoc.CreateElement("stack-trace")
                                $XUnitStacktrace.InnerText = $Callstack.Replace("\","`n")
                                $XUnitFailure.AppendChild($XUnitStacktrace) | Out-Null
                                $XUnitTest.AppendChild($XUnitFailure) | Out-Null
                            }
                        }
                        else {
                            if ($detailed) {
                                Write-Host -ForegroundColor Yellow "    Testfunction $name Skipped"
                            }
                            if ($XUnitResultFileName) {
                                $XUnitCollection.SetAttribute("skipped",([int]$XUnitCollection.GetAttribute("skipped")+1))
                                $XUnitAssembly.SetAttribute("skipped",([int]$XUnitAssembly.GetAttribute("skipped")+1))
                                $XUnitTest.SetAttribute("result", "Skip")
                            }
                        }
                        if ($result -eq "1" -and $detailed) {
                            Write-Host -ForegroundColor Red "      Error:"
                            Write-Host -ForegroundColor Red "        $firstError"
                            Write-Host -ForegroundColor Red "      Call Stack:"
                            Write-Host -ForegroundColor Red "        $($callStack.Replace('\',"`n        "))"
                        }
                        if ($XUnitResultFileName) {
                            $XUnitCollection.SetAttribute("time", $XUnitAssembly.GetAttribute("time"))
                            $XUnitCollection.SetAttribute("total", $XUnitAssembly.GetAttribute("total"))
                            $XUnitCollection.SetAttribute("passed", $XUnitAssembly.GetAttribute("passed"))
                            $XUnitCollection.SetAttribute("failed", $XUnitAssembly.GetAttribute("failed"))
                            $XUnitCollection.SetAttribute("Skipped", $XUnitAssembly.GetAttribute("skipped"))
                        }
                    }
                    else {
                    }
                }
            }
        }
    }
    if ($XUnitResultFileName) {
        $XUnitDoc.Save($XUnitResultFileName)
    }
    $clientContext.CloseForm($form)
    $allPassed
}

function Disable-SslVerification
{
    if (-not ([System.Management.Automation.PSTypeName]"SslVerification").Type)
    {
        Add-Type -TypeDefinition  @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SslVerification
{
    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
    public static void Disable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
    public static void Enable()  { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
}
"@
    }
    [SslVerification]::Disable()
}

function Enable-SslVerification
{
    if (([System.Management.Automation.PSTypeName]"SslVerification").Type)
    {
        [SslVerification]::Enable()
    }
}

function Set-TcpKeepAlive {
    Param(
        [Duration] $tcpKeepAlive
    )

    # Set Keep-Alive on Tcp Level to 1 minute to avoid Azure closing our connection
    [System.Net.ServicePointManager]::SetTcpKeepAlive($true, [int]$tcpKeepAlive.TotalMilliseconds, [int]$tcpKeepAlive.TotalMilliseconds)
}

# ---------------------------------------------------------------------------------- 
    # Copyright (c) Microsoft Corporation. All rights reserved.
    # Licensed under the MIT License. See License in the project root for
    # license information.
# ----------------------------------------------------------------------------------

<#

.SYNOPSIS
    PowerShell script that enables you to register multiple SAP systems with Azure Center for SAP solutions in parallel.

.DESCRIPTION
    This script:
    - fetches the SAP system details required for registration from the input csv file
    - creates a job for registering each SID as a VIS resource and monitors the job status
    - provides the registration status of each SID on console as well as an output csv file

.PARAMETER InputFile
    This is the full path of the csv file which has the input data for the existing SAP systems on Azure that are to be registered as a Virtual Instance for SAP solutions resource.

.PARAMETER OutputFile
    This is the full path of the output csv file which will be generated by the script with the status of the registration process.

.PARAMETER MonitoringIntervalInSeconds
    This specifies the number of seconds for which script will wait to check the status of registration during the execution

.PARAMETER MaxParallelJobs
    This specifies the limit of parallel jobs that will run at a time. There is one job triggered per SID in the input csv file.

.EXAMPLE
    C:\MassRegistrationOfSAPSystems\RegisterSIDs.ps1 -InputFile "C:\input\RegistrationData.csv" -OutputFile "C:\output\RegistrationDataOutput.csv"

.EXAMPLE
    C:\MassRegistrationOfSAPSystems\RegisterSIDs.ps1 -InputFile "C:\input\RegistrationData.csv" -OutputFile "C:\output\RegistrationDataOutput.csv" -MonitoringIntervalInSeconds 30 -MaxParallelJobs 10

#>

# Defining the parameters required for the script
[cmdletbinding()]
    Param( 
        [parameter(mandatory = $true)]
        [String]$InputFile,
        [parameter(mandatory = $true)]
        [String]$OutputFile,
        [Parameter(Mandatory = $false)]
        [Int]$MonitoringIntervalInSeconds = 30,
        [Parameter(Mandatory = $false)]
        [Int]$MaxParallelJobs = 10
    )

# Declaring variable as array for storing job definitions
$Jobdefs = @()

# Importing the input file
$file = Import-CSV $InputFile

# Iterating through each line of the input file
foreach($line in $file)
{ 
    # Getting deployment specific values
    $SID = $line.SID
    $Location = $line.Location
    $Environment = $line.Environment
    $Product = $line.Product
    $CentralServerVmId = $line.CentralServerVmId
    $ResourceGroup = $CentralServerVmId.Split("/")[4]
    $MsiID = $line.MsiId
    $ManagedRgName = $line.ManagedResourceGroupName
    $ManagedRgStorageAccountName = $line.ManagedRgStorageAccountName
    $TagVals = ($line.Tag -replace '\s','').Split(";")
    $Keys=@()
    $Values=@()

    # Creating Tag Hash Table
    foreach($TagVal in $TagVals)
    {
        $SubTag = $TagVal.Split("=")
        $Keys += $SubTag[0]
        $Values += $SubTag[1]
    }
    $i=0
    $Tag = @{}
    foreach($Key in $Keys)
    {
        $Tag += @{$Key=$Values[$i]}
        $i++
    }
    # Creating script block for parallel execution
    $ScriptBlockCopy = {
        param($ResourceGroup, $SID, $Location, $Environment, $Product, $CentralServerVmId, $ManagedRgName, $MsiID, $Tag, $ManagedRgStorageAccountName)
        New-AzWorkloadsSapVirtualInstance -ResourceGroupName $ResourceGroup -Name $SID -Location $Location -Environment $Environment -SapProduct $Product -CentralServerVmId $CentralServerVmId -ManagedResourceGroupName $ManagedRgName -IdentityType 'UserAssigned' -UserAssignedIdentity @{$MsiID=@{}} -Tag $Tag -ManagedRgStorageAccountName $ManagedRgStorageAccountName
    }

    # Generating random string for job name
    $random = -join ((65..90) + (97..122) | Get-Random -Count 8 | % {[char]$_})

    # Starting the job if the number of running jobs is less than MaxParallelJobs otherwise wait for defined time
    while ($true) {
        if ((Get-Job -State Running).Count -le $MaxParallelJobs)
        {
            Start-Job -ScriptBlock $ScriptBlockCopy -ArgumentList $ResourceGroup, $SID, $Location, $Environment, $Product, $CentralServerVmId, $ManagedRgName, $MsiID, $Tag, $ManagedRgStorageAccountName -Name $random
            break
        }
        else
        {
            Write-Host "Reached maximum parallel jobs, waiting for $MonitoringIntervalInSeconds seconds"
            Start-Sleep -Seconds $MonitoringIntervalInSeconds
        }
    }

    # Storing job definitions to monitor the status of the jobs
    $Jobdefs += New-Object PSCustomObject -Property @{JobName = $random; SID = $SID; State = "Running"}
}

Write-Host "Waiting for all jobs to complete"

# Declaring variable as array for storing completed jobs
$Completed = [System.Collections.ArrayList]::new()

while($Completed.Count -ne ($Jobdefs | Measure-Object).Count)
{
    # Waiting for monitoring interval specified before checking the status of the jobs
    Start-Sleep -Seconds $MonitoringIntervalInSeconds

    Write-Host "$($Completed.Count) Jobs completed out of $(($Jobdefs | Measure-Object).Count)"

    # Iterating through each job definition
    foreach($Jobdef in $Jobdefs)
    {

        # Checking if the job is already completed, if yes then skip the loop
        if($Completed.Contains($Jobdef.JobName))
        {
            continue
        }
        
        # Checking the status of the job
        $Job = Get-Job -Name $($Jobdef.JobName)

        # Checking if the job is not running
        if($Job.State -ne "Running")
        {
            # Getting the output of the job
            $Out = Receive-Job -Name $($Jobdef.JobName) | ConvertFrom-Json
            
            # Adding the job to completed jobs list. The job may have either succeeded or failed which can be seen from the registration status available in the output csv file.
            $null = $Completed.Add($Jobdef.JobName)
            
            # Fetching the record from the input file for the current job
            $filerec = $file | Where-Object {$_.SID -eq $Jobdef.SID}
            
            # Checking if the job succeeded or failed and update the status in record
            if($Out.properties.ProvisioningState -eq "Succeeded")
            {
                $filerec.State = "Succeeded"
            }
            else
            {
                $filerec.State = "Failed"
            }
            
            Write-Host "The registration for $($Jobdef.SID) completed with provisioning state as $($filerec.State)"
            
            # Updating the details of the job in a variable
            $Jobrec = $Jobdefs | Where-Object {$_.SID -eq $Jobdef.SID}
            
            # Updating the status of the job in same variable so that it can be used to update the status of the job in the output csv file
            $Jobrec.State = $Job.State

        }
    }
}

# Showing the status of the jobs on console
$Jobdefs | Format-Table -AutoSize

# Exporting the status of the jobs to output file
$file | Export-Csv $OutputFile -Force -NoTypeInformation
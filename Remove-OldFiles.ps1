<#	
    .NOTES
    ===========================================================================
     Created on:   	30.12.2018
     Revision date: 
     Created by:   	Daniele Catanesi
     Organization: 	https://singularvector.github.io
     Filename:     	Remove-OldFiles.ps1
     Version:		1.0.0 - Initial Script Release
    ===========================================================================
    
    .SYNOPSIS
    Scripts takes a directory as input and delete file older than defined
        number of days

    .DESCRIPTION
        Script gathers all files in the specified folder, compares files'
        creation date and if older than the value defined in the $timeSpan variable
        will log a message and delete the file.

        Script configuration is centrally read from a customizable CSV file which 
        must contain:
            - Path to scan
            - File extension to match
            - Tolerance in days
            - If recursion should be used

        Script will handle any empty/wrong value in the CSV file via default values

        Exceptions, for example wrong path or permission denied on delete, are both
        logged and notified to defined email address(es)
#>

#region Support Function
function New-LogEntry
{
    <#
	.SYNOPSIS
		Function serves as logging framework for PowerShell scripts.
	
	.DESCRIPTION
		Function allows writing log messages to a log file that can be located locally or an UNC Path additionally using buffers is supported
		to allow loggin in situations where PsProvider does not allow access to the local system for example when working with SCCM cmdlets.
		
		By default all log messages are prepended with the [INFO] tag, see -IsError or -IsWarning parameters for more details on additional tags,
		unless the -NoTag parameter is specified.
	
	.PARAMETER LogMessage
		A string representing the message to be written to the lot stream.
	
	.PARAMETER LogFilePath
		A string representing the path and file name to be used for writing log messages.
		
		If parameter is not specified $PSCommandPath will be used.
	
	.PARAMETER IsErrorMessage
		When parameter is specified log message will be prepended with the [Error] tag additionally Write-Error will be used to print
		error on console.
	
	.PARAMETER IsWarningMessage
		When parameter is specified log message will be prepended with the [Warning] tag additionally Write-Warning will be used to print
		error on console.
	
	.PARAMETER BufferOnlyInfo
		When parameter is specified log message will be saved to a temporary log-buffer with script scope for later retrieval.
	
	.PARAMETER NoConsole
		When parameter is specified console output will be suppressed.
	
	.PARAMETER BufferOnlyWarning
		When parameter is specified log message will be saved to a temporary log-buffer with script scope for later retrieval and
		message will be repended with the [Warning] tag
	
	.PARAMETER BufferOnlyError
		When parameter is specified log message will be saved to a temporary log-buffer with script scope for later retrieval and
		message will be repended with the [Error] tag
	
	.PARAMETER BufferOnly
		When parameter is specified log message will only be written to a temporary buffer that can be forwarded to file or printed on screen.
	
	.PARAMETER NoTag
		When parameter is specified tag representing message severity will be not be part of the log message.
	
	.EXAMPLE
		PS C:\> New-LogEntry -LogMessage 'This is a test message' -LogFilePath  'C:\Temp\TestLog.log'
		
		[02.29.2020 08:27:01 AM] - [INFO]: This is a test message
#>
    
    [CmdletBinding(DefaultParameterSetName = 'Info')]
    [OutputType([string], ParameterSetName = 'Info')]
    [OutputType([string], ParameterSetName = 'Error')]
    [OutputType([string], ParameterSetName = 'Warning')]
    [OutputType([string], ParameterSetName = 'NoConsole')]
    [OutputType([string], ParameterSetName = 'BufferOnly')]
    param
    (
        [Parameter(ParameterSetName = 'Error')]
        [Parameter(ParameterSetName = 'Info')]
        [Parameter(ParameterSetName = 'NoConsole')]
        [Parameter(ParameterSetName = 'Warning',
                   Mandatory = $true)]
        [Parameter(ParameterSetName = 'BufferOnly')]
        [ValidateNotNullOrEmpty()]
        [Alias('Log', 'Message')]
        [string]
        $LogMessage,
        [Parameter(ParameterSetName = 'Error',
                   Mandatory = $false)]
        [Parameter(ParameterSetName = 'Info')]
        [Parameter(ParameterSetName = 'Warning')]
        [ValidateNotNullOrEmpty()]
        [string]
        $LogFilePath,
        [Parameter(ParameterSetName = 'Error')]
        [Alias('IsError', 'WriteError')]
        [switch]
        $IsErrorMessage,
        [Parameter(ParameterSetName = 'Warning')]
        [Alias('Warning', 'IsWarning', 'WriteWarning')]
        [switch]
        $IsWarningMessage,
        [Parameter(ParameterSetName = 'BufferOnly')]
        [switch]
        $BufferOnlyInfo,
        [Parameter(ParameterSetName = 'Error')]
        [Parameter(ParameterSetName = 'Info')]
        [Parameter(ParameterSetName = 'Warning')]
        [Parameter(ParameterSetName = 'NoConsole')]
        [switch]
        $NoConsole,
        [Parameter(ParameterSetName = 'BufferOnly')]
        [switch]
        $BufferOnlyWarning,
        [Parameter(ParameterSetName = 'BufferOnly')]
        [switch]
        $BufferOnlyError,
        [Parameter(ParameterSetName = 'BufferOnly')]
        [switch]
        $BufferOnly,
        [Parameter(ParameterSetName = 'Error')]
        [Parameter(ParameterSetName = 'Info')]
        [Parameter(ParameterSetName = 'NoConsole')]
        [Parameter(ParameterSetName = 'Warning')]
        [Alias('SuppressTag')]
        [switch]
        $NoTag
    )
    
    begin
    {
        # Instantiate new mutex to implement lock
        [System.Threading.Mutex]$logMutex = New-Object System.Threading.Mutex($false, 'LogSemaphore')
        
        # Check if file locked
        [void]$logMutex.WaitOne()
        
        # Get current date timestamp
        [string]$currentDate = [System.DateTime]::Now.ToString('[MM/dd/yyyy hh:mm:ss tt]')
        
        # Use script path if no filepath is specified
        if ([string]::IsNullOrEmpty($LogFilePath) -eq $true)
        {
            # Generate log file path and name
            $LogFilePath = '{0}{1}{2}{3}' -f $PSCommandPath, '-LogFile-', $currentDate, '.log'
        }
    }
    
    process
    {
        # Initialize commandsplat 
        $paramOutFile = @{
            LiteralPath = $LogFilePath
            Append      = $true
            Encoding    = 'utf8'
        }
        
        switch ($PsCmdlet.ParameterSetName)
        {
            'Info'
            {
                switch ($PSBoundParameters.Keys)
                {
                    'NoTag'
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - : {1}' -f $currentDate, $LogMessage
                        
                        break
                    }
                    default
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - [INFO]: {1}' -f $currentDate, $LogMessage
                    }
                }
                
                # Append to log
                $paramOutFile.Add('InputObject', $tmpLogMessage)
                
                # Suppress console output
                if (!($NoConsole))
                {
                    Write-Output -InputObject $tmpLogMessage
                }
                
                Out-File @paramOutFile
                
                break
            }
            'Warning'
            {
                switch ($PSBoundParameters.Keys)
                {
                    'NoTag'
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - : {1}' -f $currentDate, $LogMessage
                        
                        break
                    }
                    default
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - [WARNING]:  {1}' -f $currentDate, $LogMessage
                    }
                }
                
                # Append to log
                $paramOutFile.Add('InputObject', $tmpLogMessage)
                
                # Suppress console output
                if (!($NoConsole))
                {
                    Write-Warning -Message $tmpLogMessage
                }
                
                Out-File @paramOutFile
                
                break
            }
            'Error'
            {
                
                switch ($PSBoundParameters.Keys)
                {
                    'NoTag'
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - : {1}' -f $currentDate, $LogMessage
                        
                        break
                    }
                    default
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - [ERROR]: {1}' -f $currentDate, $LogMessage
                    }
                }
                
                # Append to log
                $paramOutFile.Add('InputObject', $tmpLogMessage)
                
                # Suppress console output
                if (!($NoConsole))
                {
                    Write-Error -Message $tmpLogMessage
                }
                
                Out-File @paramOutFile
                
                break
            }
            
            'BufferOnly' {
                
                switch ($PSBoundParameters.Keys)
                {
                    'BufferOnlyWarning'
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - [WARNING]: {1}' -f $currentDate, $LogMessage
                    }
                    'BufferOnlyError'
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - [ERROR]: {1}' -f $currentDate, $LogMessage
                    }
                    default
                    {
                        # Format log message
                        [string]$tmpLogMessage = '{0} - [INFO]: {1}' -f $currentDate, $LogMessage
                    }
                }
                
                # Format message for buffer
                [string]$script:messageBuffer += $tmpLogMessage + [Environment]::NewLine
                
                break
            }
        }
    }
}
#endregion Support Function

# Setup environment
[datetime]$currentDate = Get-Date
[string]$dateString = $currentDate.ToString('yyyyMMdd')
[string]$logPath = '\\MyServer\ScriptLog\Remove-OldFiles\'
[string]$logTimeStamp = $currentDate.ToString('hh:mm:ss')

# Define the log path location
[string]$logFileName = $logPath + $dateString + '-RemoveOldFiles.log'

# Define Ignore control file
[string]$ignoreFile = 'ignore'

# Start a counter
[int]$deletedFiles = 0

# Get all the files in the defined path(s)
[array]$cleanupPath = Import-Csv '\\MyServer\CleanupConfig$\FilePaths.csv' -Delimiter ','

# Initialize counter
[int]$exceptionCount = 0

# Control variable
[bool]$isException = $false

#region Mail Settings Configuration

# Set mail settings
[string]$mailSender = # Mail Sender
[string[]]$mailRecipients = # 'somebody@somewhere.com', 'admin@somewhere.com'
[string]$smtpRelay = #smtpRelay
[string]$mailSubject = 'Exception in Remove-OldFiles Script'

# Setup mail body
[string]$exceptionBody = "<html lang='en'>

					<head>
    					<meta charset='UTF-8'>
    					<meta name='viewport' content='width=device-width, initial-scale=1.0'>
    					<meta http-equiv='X-UA-Compatible' content='ie=edge'>
    					<title>Exception Body</title>
    					<style>
        					body {
            					font-family: Verdana, Geneva, Tahoma, sans-serif;
            					font-size: 13px;
            					color: black;
        					}
    					</style>
					</head>

					<body>
    					<p>
        					Dear Systems Administrators,
    					</p>
    					<p>
        					<strong>Remove-OldFiles</strong> Could not process the following files/paths 
							due an exception:
    					</p>
    					<ul>"
#endregion Mail Settings Configuration

New-LogEntry -LogMessage '-----------------------------------------------------------------' -LogName $logFileName
New-LogEntry -LogMessage "	Remove-OldFiles - Execution Started at $logTimeStamp" -LogName $logFileName
New-LogEntry -LogMessage '-----------------------------------------------------------------' -LogName $logFileName

foreach ($path in $cleanupPath)
{
    # Check we have something
    if ([string]::IsNullOrEmpty($path.'CleanupPath') -eq $true)
    {
        New-LogEntry -LogMessage 'Cleanup path is empty! - No action will be taken' -IsErrorMessage -LogName $logFileName
        
        # Add exception to mail body
        $exceptionBody += '<li>
						Empty <em>CleanupPath</em> directing in CSV file
					</li>'
        
        # Increment Counter
        $exceptionCount++
        
        # Set control variable
        $isException = $true
        
        # Break loop
        continue
    }
    
    if (Get-ChildItem -Path $path.'CleanupPath' -File $ignoreFile)
    {
        New-LogEntry -LogMessage "Ignore file $ignoreFile found in $($path.'CleanupPath') - Skipping files in directory!" -LogName $logFileName
        
        # Break loop
        continue
    }
    
    New-LogEntry -LogMessage "Starting to process files in $($path.'CleanupPath')" -LogName $logFileName
    
    #region Csv format check
    # Check if we have a tolerance defined or use default
    if ([string]::IsNullOrEmpty($path.'AgeTolerance') -eq $true)
    {
        [int]$fileAgeTolerance = 90
    }
    else
    {
        [int]$fileAgeTolerance = $path.'AgeTolerance'
    }
    
    # Check if user specified extension filter
    if ([string]::IsNullOrEmpty($path.'FileExtension') -eq $true)
    {
        [string]$fileFilter = '*.*'
    }
    else
    {
        [string]$fileFilter = '*.' + $path.'FileExtension'
    }
    
    # Check if user specified recursion
    if ([string]::IsNullOrEmpty($path.'IncludeSubFolders') -eq $true)
    {
        [int]$recursiveSearch = 0
    }
    else
    {
        [int]$recursiveSearch = 1
    }
    #endregion Csv format check
    
    # Define path(s) to scan
    [string]$filePath = $path.'CleanupPath'
    
    # Check if path is still valid
    if (!(Test-Path -Path $filePath))
    {
        New-LogEntry -LogMessage "Path $filePath is not valid! - Processing aborted" -IsErrorMessage -LogName $logFileName
        
        # Add exception to mail body
        $exceptionBody += "<li>
						$filePath - Path is not valid
					</li>"
        
        # Increment Counter
        $exceptionCount++
        
        # Set control variable
        $isException = $true
        
        # Break loop
        continue
    }
    
    # File age tolerance
    [datetime]$ageTimeSpan = (Get-Date).AddDays(-$fileAgeTolerance)
    
    New-LogEntry -LogMessage "Cleanup Script parameters:
					Recursive Search: $recursiveSearch (0 means no recursion, 1 recurse in subfolders)
					File Age Tolerance: $fileAgeTolerance
					File Type Filter: $fileFilter" -LogName $logFileName
    
    # Check if search is recursive
    switch ($recursiveSearch)
    {
        0 # No recursion
        {
            try
            {
                $filesToPurge = Get-ChildItem -Path $filePath -Filter $fileFilter -File |
                Where-Object { $_.LastWriteTime -lt $ageTimeSpan }
                
                if ($filesToPurge.Count -gt 0)
                {
                    foreach ($file in $filesToPurge)
                    {
                        # Get file full path
                        [string]$fileName = $file.FullName
                        
                        New-LogEntry -LogMessage "Processing file $fileName" -LogName $logFileName
                        
                        # Calculate file age - Used for logging purposes
                        [timespan]$fileAge = ((Get-Date) - $file.LastWriteTime)
                        
                        New-LogEntry -LogMessage "File $file was last written $($fileAge.Days) days ago which is greater than $fileAgeTolerance day(s) - Deleting file" -LogName $logFileName
                        
                        try
                        {
                            # Remove file
                            Remove-Item $fileName -Confirm:$false
                            
                            # Increment counter
                            $deletedFiles++
                        }
                        catch
                        {
                            New-LogEntry -LogMessage "File $fileName cannot be removed - Please check permissions on file/folder" -LogName $logFileName
                            New-LogEntry -LogMessage "Reported exception is $Error[0]" -LogName $logFileName
                            
                            # Add exception to mail body
                            $exceptionBody += "<li>
											$fileName - File could not be deleted
										</li>"
                            
                            # Increment Counter
                            $exceptionCount++
                            
                            # Set control variable
                            $isException = $true
                        }
                    }
                }
            }
            catch
            {
                New-LogEntry -LogMessage "Issues accessing $filePath - Please check folder permissions" -LogName $logFileName
                New-LogEntry -LogMessage "Reported exception is $Error[0]" -LogName $logFileName
                
                # Add exception to mail body
                $exceptionBody += "<li>
											$filePath - Path could not be accessed
										</li>"
                
                # Increment Counter
                $exceptionCount++
                
                # Set control variable
                $isException = $true
            }
            
            break
        }
        
        1 # Recurse in subfolders
        {
            try
            {
                $filesToPurge = Get-ChildItem -Path $filePath -Filter $fileFilter -File -Recurse |
                Where-Object { $_.LastWriteTime -lt $ageTimeSpan }
                
                if ($filesToPurge.Count -gt 0)
                {
                    # Check if any folder should be skipped
                    if ($skipControl = Get-ChildItem -Path $filePath -File $ignoreFile -Recurse)
                    {
                        [array]$skippedFolders = $skipControl.'DirectoryName'
                        
                        New-LogEntry -LogMessage "Ignore file found in $skippedFolders folder(s)" -LogName $logFileName
                        New-LogEntry -LogMessage 'All child items in folder(s) will be ignored' -LogName $logFileName
                    }
                    
                    # Cycle through the filders 
                    foreach ($file in $filesToPurge)
                    {
                        [string]$fileParentContainer = $file.'DirectoryName'
                        
                        # Get file full path
                        [string]$fileName = $file.FullName
                        
                        #if ($fileParentContainer -notlike $skippedFolders)
                        if ($skippedFolders -notcontains $fileParentContainer)
                        {
                            New-LogEntry -LogMessage "Processing file $fileName" -LogName $logFileName
                            
                            # Calculate file age - Used for logging purposes
                            [timespan]$fileAge = ((Get-Date) - $file.LastWriteTime)
                            
                            New-LogEntry -LogMessage "File $file was last written $($fileAge.Days) days ago which is greater than $fileAgeTolerance day(s) - Deleting file" -LogName $logFileName
                            
                            try
                            {
                                # Remove file
                                Remove-Item $fileName -Confirm:$false
                                
                                # Increment counter
                                $deletedFiles++
                            }
                            catch
                            {
                                New-LogEntry -LogMessage "File $fileName cannot be removed - Please check permissions on file/folder" -LogName $logFileName
                                New-LogEntry -LogMessage "Reported exception is $Error[0]" -LogName $logFileName
                                
                                # Add exception to mail body
                                $exceptionBody += "<li>
											$fileName - File could not be deleted
										</li>"
                                
                                # Increment Counter
                                $exceptionCount++
                                
                                # Set control variable
                                $isException = $true
                            }
                        }
                        else
                        {
                            New-LogEntry -LogMessage "File $fileName will be skipped - Ignore file found in containing folder" -LogName $logFileName
                        }
                    }
                }
            }
            catch
            {
                New-LogEntry -LogMessage "Issues accessing $filePath - Please check folder permissions" -LogName $logFileName
                New-LogEntry -LogMessage "Reported exception is $Error[0]" -LogName $logFileName
                
                New-LogEntry -LogMessage "Issues accessing $filePath - Please check folder permissions" -LogName $logFileName
                New-LogEntry -LogMessage "Reported exception is $Error[0]" -LogName $logFileName
                
                # Add exception to mail body
                $exceptionBody += "<li>
											$filePath - Path could not be accessed
										</li>"
                
                # Increment Counter
                $exceptionCount++
                
                # Set control variable
                $isException = $true
            }
            
            break
        }
        
        default
        {
            New-LogEntry -LogMessage "Unknown value for IncludeSubFolders paramater in CSV $recursiveSearch file" -IsErrorMessage -LogName $logFileName
            New-LogEntry -LogMessage 'Entry will not be processed - Review Configuration file' -IsErrorMessage -LogName $logFileName
            
            continue
        }
    }
}

if ($isException -eq $true)
{
    New-LogEntry -LogMessage "$deletedFiles item(s) have been removed from the log directory" -LogName $logFileName
    New-LogEntry -LogMessage "A total of $exceptionCount exceptions have been reported - Sending notification email" -IsWarningMessage -LogName $logFileName
    
    # Close mail body
    $exceptionBody += "</ul>
					<p>
						Please Review log file $logFileName for more details.
					</p>
					<p>
						Kind regards,<br>
						IT Automation Team.
					</p>
				</body>
			</html>"
    
    # Send notification
    $paramSendMailMessage = @{
        From       = $mailSender
        To         = $mailRecipients
        Subject    = $mailSubject
        Body       = $exceptionBody
        Priority   = 'High'
        SmtpServer = $smtpRelay
        Encoding   = 'utf8'
    }
    
    Send-MailMessage @paramSendMailMessage
}
else
{
    New-LogEntry -LogMessage "$deletedFiles item(s) have been removed from the log directory - No Exception has been reported" -LogName $logFileName
}

# Update timestamp
[datetime]$currentDate = Get-Date
[string]$logTimeStamp = $currentDate.ToString('hh:mm:ss')

New-LogEntry -LogMessage '-----------------------------------------------------------------' -LogName $logFileName
New-LogEntry -LogMessage "	Remove-OldFiles - Execution Completed at $logTimeStamp" -LogName $logFileName
New-LogEntry -LogMessage '-----------------------------------------------------------------' -LogName $logFileName
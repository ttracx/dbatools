function Invoke-DbaDbDataMasking {
    <#
    .SYNOPSIS
        Masks data by using randomized values determined by a configuration file and a randomizer framework

    .DESCRIPTION
        TMasks data by using randomized values determined by a configuration file and a randomizer framework

        It will use a configuration file that can be made manually or generated using New-DbaDbMaskingConfig

        Note that the following column and data types are not currently supported:
        Identity
        ForeignKey
        Computed
        Hierarchyid
        Geography
        Geometry
        Xml

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        Databases to process through

    .PARAMETER Table
        Tables to process. By default all the tables will be processed

    .PARAMETER Column
        Columns to process. By default all the columns will be processed

    .PARAMETER FilePath
        Configuration file that contains the which tables and columns need to be masked

    .PARAMETER Query
        If you would like to mask only a subset of a table, use the Query parameter, otherwise all data will be masked.

    .PARAMETER Locale
        Set the local to enable certain settings in the masking

    .PARAMETER CharacterString
        The characters to use in string data. 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' by default

    .PARAMETER ExcludeTable
        Exclude specific tables even if it's listed in the config file.

    .PARAMETER ExcludeColumn
        Exclude specific columns even if it's listed in the config file.

    .PARAMETER MaxValue
        Force a max length of strings instead of relying on datatype maxes. Note if a string datatype has a lower MaxValue, that will be used instead.

        Useful for adhoc updates and testing, otherwise, the config file should be used.

    .PARAMETER ModulusFactor
        Calculating the next nullable by using the remainder from the modulus. Default is every 10.

    .PARAMETER ExactLength
        Mask string values to the same length. So 'Tate' will be replaced with 4 random characters.

    .PARAMETER ConnectionTimeout
        Timeout for the database connection in seconds. Default is 0

    .PARAMETER CommandTimeout
        Timeout for the database connection in seconds. Default is 300.

    .PARAMETER BatchSize
        Size of the batch to use to write the masked data back to the database

    .PARAMETER DictionaryFilePath
        Import the dictionary to be used in in the database masking

    .PARAMETER DictionaryExportPath
        Export the dictionary to the given path. Naming convention will be [computername]_[instancename]_[database]_Dictionary.csv

        Be careful with this feature, this export is the key to get the original values which is a security risk!

    .PARAMETER Force
        Forcefully execute commands when needed

    .PARAMETER WhatIf
        If this switch is enabled, no actions are performed but informational messages will be displayed that explain what would happen if the command were to run.

    .PARAMETER Confirm
        If this switch is enabled, you will be prompted for confirmation before executing any operations that change state.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Masking, DataMasking
        Author: Sander Stad (@sqlstad, sqlstad.nl) | Chrissy LeMaire (@cl, netnerds.net)

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Invoke-DbaDbDataMasking

    .EXAMPLE
        Invoke-DbaDbDataMasking -SqlInstance SQLDB2 -Database DB1 -FilePath C:\Temp\sqldb1.db1.tables.json

        Apply the data masking configuration from the file "sqldb1.db1.tables.json" to the db1 database on sqldb2. Prompt for confirmation for each table.

    .EXAMPLE
        Get-ChildItem -Path C:\Temp\sqldb1.db1.tables.json | Invoke-DbaDbDataMasking -SqlInstance SQLDB2 -Database DB1 -Confirm:$false

        Apply the data masking configuration from the file "sqldb1.db1.tables.json" to the db1 database on sqldb2. Do not prompt for confirmation.

    .EXAMPLE
        New-DbaDbMaskingConfig -SqlInstance SQLDB1 -Database DB1 -Path C:\Temp\clone -OutVariable file
        $file | Invoke-DbaDbDataMasking -SqlInstance SQLDB2 -Database DB1 -Confirm:$false

        Create the data masking configuration file "sqldb1.db1.tables.json", then use it to mask the db1 database on sqldb2. Do not prompt for confirmation.

    .EXAMPLE
        Get-ChildItem -Path C:\Temp\sqldb1.db1.tables.json | Invoke-DbaDbDataMasking -SqlInstance SQLDB2, sqldb3 -Database DB1 -Confirm:$false

        See what would happen if you the data masking configuration from the file "sqldb1.db1.tables.json" to the db1 database on sqldb2 and sqldb3. Do not prompt for confirmation.
    #>
    [CmdLetBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    param (
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [string[]]$Database,
        [parameter(Mandatory, ValueFromPipeline)]
        [Alias('Path', 'FullName')]
        [object]$FilePath,
        [string]$Locale = 'en',
        [string]$CharacterString = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
        [string[]]$Table,
        [string[]]$Column,
        [string[]]$ExcludeTable,
        [string[]]$ExcludeColumn,
        [string]$Query,
        [int]$MaxValue,
        [int]$ModulusFactor = 10,
        [switch]$ExactLength,
        [int]$ConnectionTimeout = 0,
        [int]$CommandTimeout = 300,
        [int]$BatchSize = 1000,
        [string[]]$DictionaryFilePath,
        [string]$DictionaryExportPath,
        [switch]$EnableException
    )
    begin {
        if ($Force) { $ConfirmPreference = 'none' }

        $supportedDataTypes = @(
            'bit', 'bigint', 'bool',
            'char', 'date',
            'datetime', 'datetime2', 'decimal',
            'float',
            'int',
            'money',
            'nchar', 'ntext', 'nvarchar',
            'smalldatetime', 'smallint',
            'text', 'time', 'tinyint',
            'uniqueidentifier', 'userdefineddatatype',
            'varchar'
        )

        $supportedFakerMaskingTypes = Get-DbaRandomizedType | Select-Object Type -ExpandProperty Type -Unique

        $supportedFakerSubTypes = Get-DbaRandomizedType | Select-Object Subtype -ExpandProperty Subtype -Unique

        $supportedFakerSubTypes += "Date"

        # Import the dictionary files
        if ($DictionaryFilePath.Count -ge 1) {
            $dictionary = @{ }

            foreach ($file in $DictionaryFilePath) {
                Write-Message -Level Verbose -Message "Importing dictionary file '$file'"
                if (Test-Path -Path $file) {
                    try {
                        # Import the keys and values
                        $items = Import-Csv -Path $file

                        # Loop through the items and define the types
                        foreach ($item in $items) {
                            if ($item.Type) {
                                $type = [type]"$($item.type)"
                            } else {
                                $type = [type]"string"
                            }

                            # Add the item to the hash array
                            if ($dictionary.Keys -notcontains $item.Key) {
                                $dictionary.Add($item.Key, ($($item.Value) -as $type))
                            }
                        }
                    } catch {
                        Stop-Function -Message "Could not import csv data from file '$file'" -ErrorRecord $_ -Target $file
                    }
                } else {
                    Stop-Function -Message "Could not import dictionary file '$file'" -ErrorRecord $_ -Target $file
                }
            }
        }
    }

    process {
        if (Test-FunctionInterrupt) {
            return
        }

        if ($FilePath.ToString().StartsWith('http')) {
            $tables = Invoke-RestMethod -Uri $FilePath
        } else {
            # Test the configuration file
            try {
                $configErrors = @()

                $configErrors += Test-DbaDbDataMaskingConfig -FilePath $FilePath -EnableException

                if ($configErrors.Count -ge 1) {
                    Stop-Function -Message "Errors found testing the configuration file." -Target $FilePath
                    return $configErrors
                }
            } catch {
                Stop-Function -Message "Something went wrong testing the configuration file" -ErrorRecord $_ -Target $FilePath
                return
            }

            # Get all the items that should be processed
            try {
                $tables = Get-Content -Path $FilePath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Stop-Function -Message "Could not parse masking config file" -ErrorRecord $_ -Target $FilePath
                return
            }
        }

        foreach ($tabletest in $tables.Tables) {
            if ($Table -and $tabletest.Name -notin $Table) {
                continue
            }

            foreach ($columntest in $tabletest.Columns) {
                if ($columntest.ColumnType -in 'hierarchyid', 'geography', 'xml', 'geometry' -and $columntest.Name -notin $Column) {
                    Stop-Function -Message "$($columntest.ColumnType) is not supported, please remove the column $($columntest.Name) from the $($tabletest.Name) table" -Target $tables -Continue
                }
            }
        }

        foreach ($instance in $SqlInstance) {
            try {
                $server = Connect-SqlInstance -SqlInstance $instance -SqlCredential $SqlCredential -MinimumVersion 9
            } catch {
                Stop-Function -Message "Error occurred while establishing connection to $instance" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            if (-not $Database) {
                $Database = $tables.Name
            }

            foreach ($dbName in $Database) {
                if (-not $DictionaryFilePath) {
                    $dictionary = @{ }
                }

                if ($server.VersionMajor -lt 9) {
                    Stop-Function -Message "SQL Server version must be 2005 or greater" -Continue
                }

                $db = $server.Databases[$($dbName)]

                $stepcounter = $nullmod = 0

                foreach ($tableobject in $tables.Tables) {
                    $uniqueValues = @()
                    $uniqueValueColumns = @()
                    $stringBuilder = [System.Text.StringBuilder]''

                    if ($tableobject.Name -in $ExcludeTable) {
                        Write-Message -Level Verbose -Message "Skipping $($tableobject.Name) because it is explicitly excluded"
                        continue
                    }

                    if ($tableobject.Name -notin $db.Tables.Name) {
                        Stop-Function -Message "Table $($tableobject.Name) is not present in $db" -Target $db -Continue
                    }

                    $dbTable = $db.Tables | Where-Object { $_.Schema -eq $tableobject.Schema -and $_.Name -eq $tableobject.Name }

                    $cleanupIdentityColumn = $false

                    if (-not ($dbTable.Columns | Where-Object Identity -eq $true)) {
                        Write-Message -Level Verbose -Message "Adding identity column to table [$($dbTable.Schema)].[$($dbTable.Name)]"
                        $query = "ALTER TABLE [$($dbTable.Schema)].[$($dbTable.Name)] ADD MaskingID BIGINT IDENTITY(1, 1) NOT NULL;"

                        Invoke-DbaQuery -SqlInstance $server -SqlCredential $SqlCredential -Database $db.Name -Query $query

                        $cleanupIdentityColumn = $true

                        $identityColumn = "MaskingID"

                        $dbTable.Columns.Refresh()
                    } else {
                        $identityColumn = $dbTable.Columns | Where-Object Identity | Select-Object -ExpandProperty Name
                    }

                    try {
                        Write-Message -Level Verbose -Message "Adding index on identity column [$($identityColumn)] in table [$($dbTable.Schema)].[$($dbTable.Name)]"

                        $query = "CREATE NONCLUSTERED INDEX NIX_$($dbTable.Name)_Masking ON [$($dbTable.Schema)].[$($dbTable.Name)]([$($identityColumn)])"

                        Invoke-DbaQuery -SqlInstance $server -SqlCredential $SqlCredential -Database $db.Name -Query $query
                    } catch {
                        Stop-Function -Message "Could not add identity index to table [$($dbTable.Schema)].[$($dbTable.Name)]" -Continue
                    }


                    try {
                        if (-not (Test-Bound -ParameterName Query)) {
                            $columnString = "[" + (($dbTable.Columns | Where-Object DataType -in $supportedDataTypes | Select-Object Name -ExpandProperty Name) -join "],[") + "]"
                            $columnString += ",[$($identityColumn)]"
                            $query = "SELECT $($columnString) FROM [$($tableobject.Schema)].[$($tableobject.Name)]"
                        }
                        [array]$data = $db.Query($query)

                    } catch {
                        Stop-Function -Message "Failure retrieving the data from table $($tableobject.Name)" -Target $Database -ErrorRecord $_ -Continue
                    }

                    # Check if the table contains unique indexes
                    if ($tableobject.HasUniqueIndex) {

                        # Loop through the rows and generate a unique value for each row
                        Write-Message -Level Verbose -Message "Generating unique values for $($tableobject.Name)"

                        for ($i = 0; $i -lt $data.Count; $i++) {

                            $rowValue = New-Object PSCustomObject

                            # Loop through each of the unique indexes
                            foreach ($index in ($db.Tables[$($tableobject.Name)].Indexes | Where-Object IsUnique -eq $true )) {

                                # Loop through the index columns
                                foreach ($indexColumn in $index.IndexedColumns) {

                                    if (-not $dbTable.Columns[$indexColumn.Name].Identity) {

                                        # Get the column mask info
                                        $columnMaskInfo = $tableobject.Columns | Where-Object Name -eq $indexColumn.Name

                                        if ($columnMaskInfo) {
                                            # Generate a new value
                                            try {
                                                if (-not $columnobject.SubType -and $columnobject.ColumnType -in $supportedDataTypes) {
                                                    $newValue = Get-DbaRandomizedValue -DataType $columnMaskInfo.SubType -Min $columnMaskInfo.MinValue -Max $columnMaskInfo.MaxValue -Locale $Locale
                                                } else {
                                                    $newValue = Get-DbaRandomizedValue -RandomizerType $columnMaskInfo.MaskingType -RandomizerSubtype $columnMaskInfo.SubType -Min $columnMaskInfo.MinValue -Max $columnMaskInfo.MaxValue -Locale $Locale
                                                }

                                            } catch {
                                                Stop-Function -Message "Failure" -Target $columnMaskInfo -Continue -ErrorRecord $_
                                            }

                                            # Check if the value is already present as a property
                                            if (($rowValue | Get-Member -MemberType NoteProperty).Name -notcontains $indexColumn.Name) {
                                                $rowValue | Add-Member -Name $indexColumn.Name -Type NoteProperty -Value $newValue
                                            }
                                        }

                                        # To be sure the values are unique, loop as long as long as needed to generate a unique value
                                        while (($uniqueValues | Select-Object -Property ($rowValue | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) -match $rowValue) {

                                            $rowValue = New-Object PSCustomObject

                                            # Loop through the index columns
                                            foreach ($indexColumn in $index.IndexedColumns) {

                                                # Get the column mask info
                                                $columnMaskInfo = $tableobject.Columns | Where-Object Name -eq $indexColumn.Name

                                                if ($columnMaskInfo) {
                                                    # Generate a new value
                                                    try {
                                                        if (-not $columnobject.SubType -and $columnobject.ColumnType -in $supportedDataTypes) {
                                                            $newValue = Get-DbaRandomizedValue -DataType $columnMaskInfo.SubType -Min $columnMaskInfo.MinValue -Max $columnMaskInfo.MaxValue -Locale $Locale
                                                        } else {
                                                            $newValue = Get-DbaRandomizedValue -RandomizerType $columnMaskInfo.MaskingType -RandomizerSubtype $columnMaskInfo.SubType -Min $columnMaskInfo.MinValue -Max $columnMaskInfo.MaxValue -Locale $Locale
                                                        }

                                                    } catch {
                                                        Stop-Function -Message "Failure" -Target $columnMaskInfo -Continue -ErrorRecord $_
                                                    }

                                                    # Check if the value is already present as a property
                                                    if (($rowValue | Get-Member -MemberType NoteProperty).Name -notcontains $indexColumn.Name) {
                                                        $rowValue | Add-Member -Name $indexColumn.Name -Type NoteProperty -Value $newValue
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    # Add the row value to the array
                                    $uniqueValues += $rowValue
                                }
                            }
                        }
                    }

                    $uniqueValueColumns = $uniqueValueColumns | Select-Object -Unique

                    $tablecolumns = $tableobject.Columns

                    if ($Column) {
                        $tablecolumns = $tablecolumns | Where-Object Name -in $Column
                    }

                    if ($ExcludeColumn) {
                        if ([string]$uniqueIndex.Columns -match ($ExcludeColumn -join "|")) {
                            Stop-Function -Message "Column present in -ExcludeColumn cannot be excluded because it's part of an unique index" -Target $ExcludeColumn -Continue
                        }

                        $tablecolumns = $tablecolumns | Where-Object Name -notin $ExcludeColumn
                    }

                    if (-not $tablecolumns) {
                        Write-Message -Level Verbose "No columns to process in $($dbName).$($tableobject.Schema).$($tableobject.Name), moving on"
                        continue
                    }

                    if ($Pscmdlet.ShouldProcess($instance, "Masking $($data.Count) row(s) for column [$($tablecolumns.Name -join ', ')] in $($dbName).$($tableobject.Schema).$($tableobject.Name)")) {
                        $elapsed = [System.Diagnostics.Stopwatch]::StartNew()

                        $totalBatches = [System.Math]::Ceiling($data.Count / $BatchSize)
                        $rowNumber = $stepcounter = $batchRowCounter = $batchCounter = 0

                        $columnsWithActions = @()
                        $columnsWithActions += $tableobject.Columns | Where-Object Action -ne $null

                        # Go through the composites
                        if ($columnsWithActions.Count -ge 1) {
                            foreach ($columnObject in $columnsWithActions) {
                                [bool]$validAction = $true

                                $columnAction = $columnobject.Action

                                $query = "UPDATE [$($tableobject.Schema)].[$($tableobject.Name)] SET [$($columnObject.Name)] = "

                                if ($columnAction.Category -eq 'DateTime') {
                                    switch ($columnAction.Type) {
                                        "Add" {
                                            $query += "DATEADD($($columnAction.SubCategory), $($columnAction.Value), [$($columnObject.Name)]);"
                                        }
                                        "Subtract" {
                                            $query += "DATEADD($($columnAction.SubCategory), - $($columnAction.Value), [$($columnObject.Name)]);"
                                        }
                                        default {
                                            $validAction = $false
                                        }
                                    }
                                } elseif ($columnAction.Category -eq 'Number') {
                                    switch ($columnAction.Type) {
                                        "Add" {
                                            $query += "[$($columnObject.Name)] + $($columnAction.Value);"
                                        }
                                        "Divide" {
                                            $query += "[$($columnObject.Name)] / $($columnAction.Value);"
                                        }
                                        "Multiply" {
                                            $query += "[$($columnObject.Name)] * $($columnAction.Value);"
                                        }
                                        "Subtract" {
                                            $query += "[$($columnObject.Name)] - $($columnAction.Value);"
                                        }
                                        default {
                                            $validAction = $false
                                        }
                                    }
                                } elseif ($columnAction.Category -eq 'Column') {
                                    switch ($columnAction.Type) {
                                        "Set" {
                                            if ($columnobject.ColumnType -like '*int*' -or $columnobject.ColumnType -in 'bit', 'bool', 'decimal', 'numeric', 'float', 'money', 'smallmoney', 'real') {
                                                $query += "$($columnAction.Value)"
                                            } elseif ($columnobject.ColumnType -in '*date*', 'time', 'uniqueidentifier') {
                                                $query += "'$($columnAction.Value)'"
                                            } else {
                                                $query += "'$($columnAction.Value)'"
                                            }
                                        }
                                        "Nullify" {
                                            if ($columnobject.Nullable) {
                                                $query += "NULL"
                                            } else {
                                                $validAction = $false
                                            }
                                        }
                                        default {
                                            $validAction = $false
                                        }
                                    }
                                }
                                # Add the query to the rest
                                if ($validAction) {
                                    $null = $stringBuilder.AppendLine($query)
                                }
                            }

                            try {
                                if ($stringBuilder.Length -ge 1) {
                                    Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db.Name -Query $stringBuilder.ToString()
                                }
                            } catch {
                                Stop-Function -Message "Error updating $($tableobject.Schema).$($tableobject.Name): $_" -Target $stringBuilder -Continue -ErrorRecord $_
                            }

                            $null = $stringBuilder.Clear()
                        }

                        # Loop through each of the rows and change them
                        foreach ($columnobject in $tablecolumns) {
                            # Check if column is does not contain an action
                            if ($columnobject.Name -notin $columnsWithActions.Name) {
                                foreach ($row in $data) {
                                    if ((($batchCounter++) % 100) -eq 0) {
                                        $progressParams = @{
                                            StepNumber = $batchCounter
                                            TotalSteps = $totalBatches
                                            Activity   = "Masking $($data.Count) rows in $($tableobject.Schema).$($tableobject.Name) in $($dbName) on $instance"
                                            Message    = "Generating Updates"
                                        }

                                        Write-ProgressHelper @progressParams
                                    }

                                    $updates = @()
                                    $newValue = $null

                                    # Generate a unique value for the row
                                    if ($columnobject.ColumnType -notin $supportedDataTypes) {
                                        Stop-Function -Message "Unsupported data type '$($columnobject.ColumnType)' for column $($columnobject.Name)" -Target $columnobject -Continue
                                    }

                                    if ($columnobject.MaskingType -notin $supportedFakerMaskingTypes) {
                                        Stop-Function -Message "Unsupported masking type '$($columnobject.MaskingType)' for column $($columnobject.Name)" -Target $columnobject -Continue
                                    }

                                    if ($columnobject.SubType -notin $supportedFakerSubTypes) {
                                        Stop-Function -Message "Unsupported masking sub type '$($columnobject.SubType)' for column $($columnobject.Name)" -Target $columnobject -Continue
                                    }

                                    if ($columnobject.KeepNull -and (($row.($columnobject.Name)).GetType().Name -eq 'DBNull')) {
                                        $newValue = $null
                                    } elseif (-not $columnobject.KeepNull -and $columnobject.Nullable -and (($nullmod++) % $ModulusFactor -eq 0)) {
                                        $newValue = $null
                                    } elseif ($tableobject.HasUniqueIndex -and $columnobject.Name -in $uniqueValueColumns) {

                                        if ($uniqueValues.Count -lt 1) {
                                            Stop-Function -Message "Could not find any unique values in dictionary" -Target $tableobject
                                            return
                                        }

                                        $newValue = $uniqueValues[$rowNumber].$($columnobject.Name)

                                    } elseif ($columnobject.Deterministic -and $dictionary.ContainsKey($row.$($columnobject.Name) )) {
                                        $newValue = $dictionary.Item($row.$($columnobject.Name))
                                    } else {
                                        # make sure min is good
                                        if ($columnobject.MinValue) {
                                            $min = $columnobject.MinValue
                                        } else {
                                            if ($columnobject.CharacterString) {
                                                $min = 1
                                            } else {
                                                $min = 0
                                            }
                                        }

                                        # make sure max is good
                                        if ($MaxValue) {
                                            if ($columnobject.MaxValue -le $MaxValue) {
                                                $max = $columnobject.MaxValue
                                            } else {
                                                $max = $MaxValue
                                            }
                                        } else {
                                            $max = $columnobject.MaxValue
                                        }

                                        if (-not $columnobject.MaxValue -and -not (Test-Bound -ParameterName MaxValue)) {
                                            $max = 10
                                        }

                                        if ($columnobject.CharacterString) {
                                            $charstring = $columnobject.CharacterString
                                        } else {
                                            $charstring = $CharacterString
                                        }

                                        if ((-not $columnobject.MinValue -or -not $columnobject.MaxValue) -and ($columnobject.ColumnType -match 'date')) {
                                            if (-not $columnobject.MinValue) {
                                                $min = (Get-Date).AddDays(-365)
                                            }
                                            if (-not $columnobject.MaxValue) {
                                                $max = (Get-Date).AddDays(365)
                                            }
                                        }

                                        try {
                                            $newValue = $null

                                            if ($columnobject.SubType.ToLowerInvariant() -eq 'shuffle') {
                                                if ($columnobject.ColumnType -in 'bigint', 'char', 'int', 'nchar', 'nvarchar', 'smallint', 'tinyint', 'varchar') {
                                                    $newValue = Get-DbaRandomizedValue -RandomizerType "Random" -RandomizerSubtype "Shuffle" -Value ($row.$($columnobject.Name)) -Locale $Locale

                                                    $newValue = ($newValue -join '')
                                                } elseif ($columnobject.ColumnType -in 'decimal', 'numeric', 'float', 'money', 'smallmoney', 'real') {
                                                    $valueString = ($row.$($columnobject.Name)).ToString()

                                                    $commaIndex = $valueString.IndexOf(",")
                                                    $dotIndex = $valueString.IndexOf(".")

                                                    $newValue = (Get-DbaRandomizedValue -RandomizerType Random -RandomizerSubType Shuffle -Value (($valueString -replace ',', '') -replace '\.', '')) -join ''

                                                    if ($commaIndex -ne -1) {
                                                        $newValue = $newValue.Insert($commaIndex, ',')
                                                    }

                                                    if ($dotIndex -ne -1) {
                                                        $newValue = $newValue.Insert($dotIndex, '.')
                                                    }
                                                }
                                            } elseif (-not $columnobject.SubType -and $columnobject.ColumnType -in $supportedDataTypes) {
                                                $newValue = Get-DbaRandomizedValue -DataType $columnobject.ColumnType -Min $min -Max $max -CharacterString $charstring -Format $columnobject.Format -Locale $Locale
                                            } else {
                                                $newValue = Get-DbaRandomizedValue -RandomizerType $columnobject.MaskingType -RandomizerSubtype $columnobject.SubType -Min $min -Max $max -CharacterString $charstring -Format $columnobject.Format -Locale $Locale
                                            }
                                        } catch {

                                            Stop-Function -Message "Failure" -Target $columnobject -Continue -ErrorRecord $_
                                        }
                                    }

                                    if ($null -eq $newValue -and $columnobject.Nullable -eq $true) {
                                        $updates += "[$($columnobject.Name)] = NULL"
                                    } elseif ($columnobject.ColumnType -in 'bit', 'bool') {
                                        if ($columnValue) {
                                            $updates += "[$($columnobject.Name)] = 1"
                                        } else {
                                            $updates += "[$($columnobject.Name)] = 0"
                                        }
                                    } elseif ($columnobject.ColumnType -like '*int*' -or $columnobject.ColumnType -in 'decimal', 'numeric', 'float', 'money', 'smallmoney', 'real') {
                                        $updates += "[$($columnobject.Name)] = $newValue"
                                    } elseif ($columnobject.ColumnType -in 'uniqueidentifier') {
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    } elseif ($columnobject.ColumnType -eq 'datetime') {
                                        $newValue = ([datetime]$newValue).Tostring("yyyy-MM-dd HH:mm:ss.fff")
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    } elseif ($columnobject.ColumnType -eq 'datetime2') {
                                        $newValue = ([datetime]$newValue).Tostring("yyyy-MM-dd HH:mm:ss.fffffff")
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    } elseif ($columnobject.ColumnType -like 'date') {
                                        $newValue = ([datetime]$newValue).Tostring("yyyy-MM-dd")
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    } elseif ($columnobject.ColumnType -like '*date*') {
                                        $newValue = ([datetime]$newValue).Tostring("yyyy-MM-dd HH:mm:ss")
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    } elseif ($columnobject.ColumnType -like 'time') {
                                        $newValue = ([datetime]$newValue).Tostring("HH:mm:ss.fffffff")
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    } elseif ($columnobject.ColumnType -eq 'xml') {
                                        # nothing, unsure how i'll handle this
                                    } else {
                                        $newValue = ($newValue).Tostring().Replace("'", "''")
                                        $updates += "[$($columnobject.Name)] = '$newValue'"
                                    }

                                    if ($columnobject.Deterministic -and -not $dictionary.ContainsKey($row.$($columnobject.Name) )) {
                                        $dictionary.Add($row.$($columnobject.Name), $newValue)
                                    }


                                    $null = $stringBuilder.AppendLine("UPDATE [$($tableobject.Schema)].[$($tableobject.Name)] SET $($updates -join ', ') WHERE [$($identityColumn)] = $($row.$($identityColumn)); ")
                                }

                                $batchRowCounter++

                                if ($batchRowCounter -eq $BatchSize) {
                                    $batchCounter++

                                    $progressParams = @{
                                        StepNumber = $batchCounter
                                        TotalSteps = $totalBatches
                                        Activity   = "Masking $($data.Count) rows in $($tableobject.Schema).$($tableobject.Name) in $($dbName) on $instance"
                                        Message    = "Executing Batch $batchCounter/$totalBatches"
                                    }

                                    Write-ProgressHelper @progressParams

                                    Write-Message -Level Verbose -Message "Executing batch $batchCounter/$totalBatches"

                                    try {
                                        Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db.Name -Query $stringBuilder.ToString()
                                    } catch {
                                        Stop-Function -Message "Error updating $($tableobject.Schema).$($tableobject.Name): $_" -Target $stringBuilder -Continue -ErrorRecord $_
                                    }

                                    $null = $stringBuilder.Clear()
                                    $batchRowCounter = 0
                                }

                                # Increase the row number
                                $rowNumber++
                            }

                            if ($stringBuilder.Length -ge 1) {

                                $progressParams = @{
                                    StepNumber = $batchCounter
                                    TotalSteps = $totalBatches
                                    Activity   = "Masking $($data.Count) rows in $($tableobject.Schema).$($tableobject.Name) in $($dbName) on $instance"
                                    Message    = "Executing Batch $batchCounter/$totalBatches"
                                }

                                #Write-ProgressHelper @progressParams

                                try {
                                    Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db.Name -Query $stringBuilder.ToString()
                                } catch {
                                    Stop-Function -Message "Error updating $($tableobject.Schema).$($tableobject.Name): $_" -Target $stringBuilder -Continue -ErrorRecord $_
                                }

                                $batchCounter++
                            }
                        }

                        $null = $stringBuilder.Clear()

                        $columnsWithComposites = @()
                        $columnsWithComposites += $tableobject.Columns | Where-Object Composite -ne $null

                        # Check for both special actions
                        if (($columnsWithComposites.Count -ge 1) -and ($columnsWithActions.Count -ge 1)) {
                            Stop-Function -Message "You cannot use both composites and actions"
                        }

                        # Go through the composites
                        if ($columnsWithComposites.Count -ge 1) {
                            foreach ($columnObject in $columnsWithComposites) {

                                $compositeItems = @()

                                foreach ($columnComposite in $columnObject.Composite) {
                                    if ($columnComposite.Type -eq 'Column') {
                                        $compositeItems += "[$($columnComposite.Value)]"
                                    } elseif ($columnComposite.Type -in $supportedFakerMaskingTypes) {
                                        try {
                                            $newValue = $null

                                            if ($columnobject.SubType -in $supportedDataTypes) {
                                                $newValue = Get-DbaRandomizedValue -DataType $columnobject.SubType -CharacterString $charstring -Min $columnComposite.Min -Max $columnComposite.Max -Locale $Locale
                                            } else {
                                                $newValue = Get-DbaRandomizedValue -RandomizerType $columnComposite.Type -RandomizerSubType $columnComposite.Subtype  -CharacterString $charstring -Min $columnComposite.Min -Max $columnComposite.Max -Locale $Locale
                                            }
                                        } catch {
                                            Stop-Function -Message "Failure" -Target $faker -Continue -ErrorRecord $_
                                        }

                                        if ($columnobject.ColumnType -match 'int') {
                                            $compositeItems += " $newValue"
                                        } elseif ($columnobject.ColumnType -in 'bit', 'bool') {
                                            if ($columnValue) {
                                                $compositeItems += "1"
                                            } else {
                                                $compositeItems += "0"
                                            }
                                        } else {
                                            $newValue = ($newValue).Tostring().Replace("'", "''")
                                            $compositeItems += "'$newValue'"
                                        }
                                    } elseif ($columnComposite.Type -eq 'Static') {
                                        $compositeItems += "'$($columnComposite.Value)'"
                                    } else {
                                        $compositeItems += ""
                                    }
                                }

                                $compositeItems = $compositeItems | ForEach-Object { $_ = "ISNULL($($_), '')"; $_ }

                                $null = $stringBuilder.AppendLine("UPDATE [$($tableobject.Schema)].[$($tableobject.Name)] SET [$($columnObject.Name)] = $($compositeItems -join ' + ')")
                            }

                            try {
                                Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db.Name -Query $stringBuilder.ToString()
                            } catch {
                                Stop-Function -Message "Error updating $($tableobject.Schema).$($tableobject.Name): $_" -Target $stringBuilder -Continue -ErrorRecord $_
                            }
                        }

                        try {
                            Write-Message -Level Verbose -Message "Removing index on identity column [$($identityColumn)] in table [$($dbTable.Schema)].[$($dbTable.Name)]"

                            $query = "DROP INDEX [NIX_$($dbTable.Name)_Masking] ON [$($dbTable.Schema)].[$($dbTable.Name)]"

                            Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db.Name -Query $query
                        } catch {
                            Stop-Function -Message "Could not remove identity index to table [$($dbTable.Schema)].[$($dbTable.Name)]" -Continue
                        }

                        if ($cleanupIdentityColumn) {
                            try {
                                Write-Message -Level Verbose -Message "Removing identity column [$($identityColumn)] from table [$($dbTable.Schema)].[$($dbTable.Name)]"

                                $query = "ALTER TABLE [$($dbTable.Schema)].[$($dbTable.Name)] DROP COLUMN [$($identityColumn)]"

                                Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $db.Name -Query $query

                            } catch {
                                Stop-Function -Message "Could not remove identity column from table [$($dbTable.Schema)].[$($dbTable.Name)]" -Continue
                            }
                        }

                        try {
                            [pscustomobject]@{
                                ComputerName = $db.Parent.ComputerName
                                InstanceName = $db.Parent.ServiceName
                                SqlInstance  = $db.Parent.DomainInstanceName
                                Database     = $dbName
                                Schema       = $tableobject.Schema
                                Table        = $tableobject.Name
                                Columns      = $tableobject.Columns.Name
                                Rows         = $($data.Count)
                                Elapsed      = [prettytimespan]$elapsed.Elapsed
                                Status       = "Masked"
                            }
                        } catch {
                            Stop-Function -Message "Error updating $($tableobject.Schema).$($tableobject.Name).`n$updatequery" -Target $updatequery -Continue -ErrorRecord $_
                        }
                    }

                    # Empty the unique values array
                    $uniqueValues = $null
                }

                # Export the dictionary when needed
                if ($DictionaryExportPath) {
                    try {
                        if (-not (Test-Path -Path $DictionaryExportPath)) {
                            New-Item -Path $DictionaryExportPath -ItemType Directory
                        }

                        Write-Message -Message "Writing dictionary for $($db.Name)" -Level Verbose

                        $filenamepart = $server.Name.Replace('\', '$').Replace('TCP:', '').Replace(',', '.')
                        $dictionaryFileName = "$DictionaryExportPath\$($filenamepart).$($db.Name).Dictionary.csv"

                        if (-not $script:isWindows) {
                            $dictionaryFileName = $dictionaryFileName.Replace("\", "/")
                        }

                        $dictionary.GetEnumerator() | Sort-Object Key | Select-Object Key, Value, @{Name = "Type"; Expression = { $_.Value.GetType().Name } } | Export-Csv -Path $dictionaryFileName -NoTypeInformation

                        Get-ChildItem -Path $dictionaryFileName
                    } catch {
                        Stop-Function -Message "Something went wrong writing the dictionary to the $DictionaryExportPath" -Target $DictionaryExportPath -Continue -ErrorRecord $_
                    }
                }
            } # End foreach database
        } # End foreach instance
    } # End process block
} # End
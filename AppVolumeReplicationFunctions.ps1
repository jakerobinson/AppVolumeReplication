

function New-ContentLibraryPair {
    param (
        $sourceServer,
        $sourceDatastore,
        $libraryName,
        $targetServer,
        $targetDatastore
    )

    $sourceContentLibrary = Get-ContentLibrary -Server $sourceServer | Where-Object { $_.name -eq $libraryName }
    if ($sourceContentLibrary) {
        Write-Host "Content Library '$libraryName' already exists on source server. We will use this one."
    }
    else {
        Write-Host "Creating source Content Library: $libraryName..."
        $sourceContentLibrary = New-ContentLibrary -datastore $sourceDatastore -name $libraryName -Description 'AppStack Sync' -Published -server $sourceServer
    }

    $targetContentLibrary = Get-ContentLibrary -Server $targetServer | Where-Object { $_.name -eq $libraryName }
    if ($targetContentLibrary) {
        Write-Host "Content Library '$libraryName' already exists on target. We will use this one."
    }
    else {
        Write-Host "Creating target Content Library: $libraryName..."
        $sourceURI = $sourceContentLibrary.PublishURL.AbsoluteURI
        $targetContentLibrary = New-ContentLibrary -Datastore $targetDatastore -Name $libraryName -SubscriptionUrl $sourceURI  -server $targetServer
    }
    
    @{
        'source' = $sourceContentLibrary;
        'target' = $targetContentLibrary;
    }
}


function New-ContentLibraryItemFromURL() {
    [CmdletBinding()]
    param(
        [String]
        $Name,

        [String]
        $FileUrl,
 
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $LibraryName,
 
        [String]
        $Description = "",

        [AllowNull()]
        [String]
        $Server
    )

    BEGIN { }

    PROCESS {
        try {

            $library = Get-ContentLibrary -Name $LibraryName -Server $Server

            # Library Item Service
            $clItemService = Get-CisService com.vmware.content.library.item -Server $Server

            # Library Item Spec
            $clItemCreateSpec = $clItemService.Help.create.create_spec.Create()
            $clItemCreateSpec.name = $Name
            $clItemCreateSpec.description = $Description
            $clItemCreateSpec.library_Id = $library.Id
            $clItemCreateSpec.type = 'UNKNOWN'
            
            # create item with spec
            $itemId = $clItemService.create(([guid]::NewGuid().ToString()), $clItemCreateSpec)

            # Update_Session Service
            $clUpdateSessionService = Get-CisService com.vmware.content.library.item.update_session -Server $Server
            
            $clUpdateSessionCreateSpec = $clUpdateSessionService.Help.create.create_spec.Create()
            $clUpdateSessionCreateSpec.library_item_id = $itemId.value
            $updateSessionId = $clUpdateSessionService.create(([guid]::NewGuid().ToString()), $clUpdateSessionCreateSpec)

            $clUpdateSessionFileService = Get-CisService 'com.vmware.content.library.item.updatesession.file' -Server $Server
      
  
            $clUpdateSessionFileCreateSpec = $clUpdateSessionFileService.Help.add.file_spec.Create()
            $clUpdateSessionFileCreateSpec.name = $name
            $clUpdateSessionFileCreateSpec.source_type = 'PULL'
            $clUpdateSessionFileCreateSpec.source_endpoint.uri = $FileUrl

            $clUpdateSessionFileService.add($updateSessionId.Value, $clUpdateSessionFileCreateSpec)
            $clUpdateSessionService.complete($updateSessionId.Value)

            $itemId
        }
        catch {
            Write-Error $_
        }
    }
 
    END { }
}

function New-VsanDirectory {
    param (
        $datastore,
        $name,
        $server
    )
    $serviceInstance = Get-View ServiceInstance -Server $server
    $datastoreNamespaceMgr = Get-View $serviceInstance.Content.DatastoreNamespaceManager -server $server
    $folderPath = $datastoreNamespaceMgr.createDirectory($datastore.ExtensionData.moref, $name, "")
    $folderPath.split("/")[-1]
}

Function Get-VSANDatastoreFolders {
    # List-DatastoreFolders -DatastoreName WorkloadDatastore
    Param (
        [Parameter(Mandatory = $true)]$Datastore,
        [Parameter(Mandatory = $true)][String]$Server
    )
    
    $br = Get-View $datastore.ExtensionData.Browser -Server $Server
    $spec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
    $folderFileQuery = New-Object Vmware.Vim.FolderFileQuery
    $spec.Query = $folderFileQuery
    $fileQueryFlags = New-Object VMware.Vim.FileQueryFlags
    $fileQueryFlags.fileOwner = $false
    $fileQueryFlags.fileSize = $false
    $fileQueryFlags.fileType = $true
    $fileQueryFlags.modification = $false
    $spec.details = $fileQueryFlags
    $spec.sortFoldersFirst = $true
    $results = $br.SearchDatastore("[$($datastore.Name)]", $spec)
    
    $folders = @()
    $files = $results.file
    foreach ($file in $files) {
        if ($file.getType().Name -eq "FolderFileInfo") {
            $folderPath = $results.FolderPath + " " + $file.Path
    
            $tmp = [pscustomobject] @{
                Name = $file.FriendlyName;
                Path = $folderPath;
            }
            $folders += $tmp
        }
    }
    $folders
}
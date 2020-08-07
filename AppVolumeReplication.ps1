# Import functions
. ./AppVolumeReplicationFunctions.ps1

# Modify these variables for your environment.

$source = @{
    'connection' = @{
        'server'   = "[VCENTER FQDN]";
        'username' = "cloudadmin@vmc.local";
        'password' = "[PASSWORD]";
    }
    'config'     = @{
        'datastoreName' = "WorkloadDatastore";
    }
}

$target = @{
    'connection' = @{
        'server'   = "[VCENTER FQDN]";
        'username' = "cloudadmin@vmc.local";
        'password' = "[PASSWORD]";
    }
    'config'     = @{
        'datastoreName' = "WorkloadDatastore";
    }
}

# Change these if App Volumes are not in the default folders on the datastore, or remove the one you don't need.
$appFolders = @(
    @{'name' = "appvolumes/packages" },
    @{'name' = "cloudvolumes/apps" }
)

# Connection and Setup
# Connect to vCenters, mount datastore drives.

@($source, $target) | ForEach-Object {
    $conn = $_.connection
    Write-Output "Connecting to $($conn.server)..."
    Connect-VIServer @conn | Out-Null
    Connect-CisServer @conn | Out-Null

    $_.datastore = Get-Datastore -Name $_.config.datastoreName -Server $conn.server
    $_.psDriveName = $conn.server.split(".")[1]
   
    New-PSDrive -Location $_.datastore -name $conn.server.split(".")[1] -PSProvider VimDatastore -Root "\" | Out-Null
    $_.contentLibraries = @()
}

$source.vSANObjects = Get-VSANDatastoreFolders -datastore $source.datastore -server $source.connection.server

# Copy to Content Library
# Create Content Libraries if not already there, Get list of files on the datastore, construct URLs, and upload to individual content libraries.
# I am using multiple content libraries here since it doesn't cost us anything and it's an easy way to know where the files will go once replicated.
# I'm still contemplating doing a source-target datastore comparison to make the paths match and to make things more efficient for replication, but this is simple and safe.

$appFolders | ForEach-Object {
    $name = $_.name.split("/")[0]
    $subFolder = $_.name.split("/")[1]
    $clParams = @{
        'sourceServer'    = $source.connection.server
        'sourceDatastore' = $source.datastore
        'libraryName'     = $name
        'targetServer'    = $target.connection.server
        'targetDatastore' = $target.datastore
    }

    $clPair = New-ContentLibraryPair @clParams

    $source.contentLibraries += $clPair.source
    $target.contentLibraries += $clPair.target

    $_.UUID = ($source.vSANObjects | Where-Object { $_.name -eq $name }).path.split(" ")[1]

    # Get all files recursively, ignoring hidden 'dot' files, and the child app folders themselves.
    $_.files = Get-ChildItem -Recurse -Path "$($source.psDriveName):\$($_.UUID)\$subFolder\" | 
        Where-Object { ($_.name -notlike ".*") -and ($_ -isNot [VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.DatastoreFolderImpl])}

    $_.fileURLs = @()
    foreach ($file in $_.files) {
        if (Get-ContentLibraryItem -Name "$($file.FolderPath.split("/")[-1])__$($file.name)" -Server $source.connection.server -ContentLibrary $name -ErrorAction SilentlyContinue) {
            Write-Output "$($file.FolderPath.split("/")[-1])__$($file.name) already in $name"
        }
        else {
            $fileUrl = "$($source.datastore.ExtensionData.info.Url)/$($_.UUID)/$subFolder/$($file.FolderPath.split("/")[-1])/$($file.name)"
            New-ContentLibraryItemFromUrl -name "$($file.FolderPath.split("/")[-1])__$($file.name)" -FileUrl $fileUrl -LibraryName $name -server $source.connection.server
        }
    }
}

# Intermission
# Here we wait for File uploads to happen and then for the remote sync to take place.
# The two types of tasks I've noticed are the upload and nfc copy tasks.

Write-Output "Waiting for file uploads to complete..."
Get-Task -Server $source.connection.server | Where-Object { $_.Name -eq "Upload Files to a Library Item" } | Wait-Task
Get-Task -Server $source.connection.server | Where-Object { $_.Name -eq "NfcCopy_Task" } | Wait-Task

$target.contentLibraries | ForEach-Object {
    Write-Output "Syncing $($_.name) source and target Content Libraries..."
    Set-ContentLibrary -SubscribedContentLibrary $_.name -Sync -Server $target.connection.server | Out-Null
}

Write-Output "Waiting for Content Library sync tasks to complete..."
Get-Task -server $target.connection.server | Where-Object { $_.Name -eq "Sync Library" } | Wait-Task

# After sync, we're on to the operations on the target side.
# Once we get the vSAN Object UUIDs, we can move on to determining if we need to create root datastore folders.
# After that, we do direct datastore to datastore copies. 
# Content Library renames files, so we have to do some work to name them back.

$target.vSANObjects = Get-VSANDatastoreFolders -datastore $target.datastore -server $target.connection.server

$appFolders | ForEach-Object {
    $rootFolder = $_.name.split("/")[0]
    $subFolder = $_.name.split("/")[1]
    $contentLibraryUUID = ($target.contentLibraries | Where-Object name -eq $rootFolder).id
    $contentLibraryFolderUUID = ($target.vSANObjects | Where-Object { $_.name -eq "contentlib-$($contentLibraryUUID)" }).path.split(" ")[1]

    if ($target.vSANObjects.name.contains($rootFolder)) { 
        $folderUUID = ($target.vSANObjects | Where-Object {$_.name -eq $rootFolder}).path.split(" ")[1]
    }
    else {
        $folderUUID = New-VsanDirectory -Datastore $target.datastore -Name $rootFolder -Server $target.connection.server
    }

    New-Item -path "$($target.psDriveName):\$folderUUID\$subFolder" -Type Directory -ErrorAction SilentlyContinue | Out-Null

    $contentLibraryFiles = Get-ChildItem -recurse -path "$($target.psDriveName):\$contentLibraryFolderUUID\" | Where-Object { !$_.PSIsContainer } | Where-Object name -notlike ".*"

    $contentLibraryFiles | ForEach-Object {
        if ($_.name.IndexOf("__") >= 0) {
            $childFolder = $_.name.Substring(0,$_.name.LastIndexOf("_")).split("__")[0]
            $name = $_.name.Substring(0,$_.name.LastIndexOf("_")).split("__")[1]
            $folderPath = "$folderUUID\$subFolder\$childFolder"
        }
        else {
            $name = $_.name.Substring(0,$_.name.LastIndexOf("_"))
            $folderPath = "$folderUUID\$subFolder"
        }

        $path = "$($target.psDriveName):\$($_.DatastoreFullPath.split(' ')[1])"
        $extension = $_.name.Split('.')[-1]
        $destinationFolder = "$($target.psDriveName):\$folderPath"
        $absolutePath = "$($target.psDriveName):\$folderPath\$name.$extension"

        $existingFiles = Get-ChildItem $destinationFolder

        if ($existingFiles -and $existingFiles.name.contains("$name.$extension")) {
            Write-Output "$name.$extension already exists in $rootFolder."
        }
        else {
            Write-Output "Copying $name.$extension to $folderPath..."
            New-Item -ItemType Folder -Path $destinationFolder -ErrorAction SilentlyContinue
            Copy-Item -Path $path -Destination $absolutePath
        }

    }

}
# The Copy-Item tasks seem to be synchronous, so we don't need to wait for any tasks to complete. We're done.
Write-Output "App Volume Sync Complete!"

@($source, $target) | ForEach-Object {
    Remove-PSDrive -name $_.psDriveName
}
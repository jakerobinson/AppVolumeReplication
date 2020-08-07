# AppVolumeReplication

### Description
This script replicates App Volumes between a source and target vSphere environment using Content Library.

### Instructions

1. Download AppVolumeReplication.ps1 and AppVolumeReplicationFunctions.ps1.
2. Modify the AppVolumeReplication.ps1 script with the hostnames and passwords for the source and target environments.
3. Open PowerShell and install PowerCLI if not already there: Install-Module VMware.PowerCLI -scope CurrentUser
4. Run AppVolumeReplication.ps1: `./AppVolumeReplication.ps1`



# **Drupal 10 Azure Container Apps (ACA) Migration**

## **1\. Project Overview**

* **Source:** cPanel (Drupal 10, Composer-based).  
* **Destination:** Azure Container Apps (Serverless, Autoscaling, VNet Isolated).  
* **Files:** Azure Managed Files (SMB/NFS) for /private and /public.  
* **Database:** Azure Database for MySQL (Flexible Server).

## **2\. Updated Architecture & Update Flow**

Unlike cPanel, where the server is modified in place, the Azure architecture uses **Immutable Revisions**.

| Feature | cPanel (Current) | Azure ACA (New) |
| :---- | :---- | :---- |
| **Update Mechanism** | Git Pull \+ Remote Composer | GitHub Action Build \+ Container Push |
| **Downtime** | Risk during composer install | Zero (Blue/Green Revision switching) |
| **Environment** | Shared/Static | Isolated/Disposable Containers |
| **Scalability** | Manual/Vertical | Automatic/Horizontal (Scale to Zero) |

## ---

**3\. Phase 1: Infrastructure (Bicep)**

* **Networking:** VNet with subnets for App and Database.  
* **Storage:** Storage Account with drupal-public and drupal-private shares.  
* **Compute:** ACA Environment \+ ACR (Azure Container Registry).  
* **Secrets:** Managed Identities for "keyless" access to storage.

## ---

**4\. Phase 2: The "Grand Migration" (cPanel to Azure)**

**Script: migrate.sh**

1. **DB:** Export from cPanel → Sanitize → Import to Azure MySQL via mysql-client.  
2. **Files:** Connect to cPanel via SSH/SFTP → Stream /sites/default/files and your private directory directly to Azure File Shares using azcopy.

## ---

**5\. Phase 3: The Update Engine (GitHub Actions)**

**Workflow: drupal-update.yml**

1. **Trigger:** Manual or Scheduled (e.g., weekly).  
2. **Composer:** Run composer update inside the GitHub Runner.  
3. **Lock:** Commit the updated composer.lock back to the repository.  
4. **Build:** Generate a new Docker Image containing the updated code/vendor.  
5. **Push:** Upload image to **Azure Container Registry**.  
6. **Deploy:** Update the Container App to the new image.  
7. **Post-Deploy:** The workflow executes drush updb and drush cr via an Azure "Post-deployment" hook.

## ---

**6\. Phase 4: Lifecycle Automation (The "Colorful" Scripts)**

We will generate a set of interactive, color-coded Bash scripts for your local machine:

* **azure-up.sh**: Deploys/Updates the entire Bicep stack.  
* **azure-logs.sh**: Streams real-time logs from the container for debugging.  
* **azure-backup.sh**: Triggers an on-demand snapshot of the DB and File Shares.  
* **azure-nuke.sh**: Tears down the stack for cost savings (with safety prompts).

## ---

**7\. Next Steps for the AI**

1. **Generate main.bicep**: Define the VNet, MySQL, Storage, and ACR.  
2. **Generate Dockerfile**: Create the PHP-FPM/Nginx environment.  
3. **Generate github-action.yml**: Define the automated build and Drupal update logic.  
4. **Generate migrate.sh**: The script to pull data from your current cPanel host.


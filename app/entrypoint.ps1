## what to do:

# Get and clone the source repository

# find all repos matching topics supplied

# clone, branch and pr if required

# close off

## Logging should be able to undertstand both file and std out

[CmdletBinding()]
param (
  [String]
  [ValidateNotNullOrEmpty()]
  $DestinationRepoOwner = $ENV:GCR_DESTINATION_REPO_OWNER,
  [String]
  [ValidateNotNullOrEmpty()]
  $DestinationRepoTopicsCsv = $ENV:GCR_DESTINATION_REPO_TOPICS,
  [String]
  [ValidateNotNullOrEmpty()]
  $BranchName = $ENV:GCR_BRANCH_NAME,
  [String]
  [ValidateNotNullOrEmpty()]
  $PullRequestTitle = $ENV:GCR_PULL_REQUEST_TITLE,
  [String]
  $PullRequestLabels = $ENV:GCR_PULL_REQUEST_LABELS,
  [String]
  $GitName = $ENV:GCR_GIT_NAME,
  [String]
  $GitEmail = $ENV:GCR_GIT_EMAIL,
  [String]
  $ChangeLogLocation = $ENV:GCR_CHANGELOG_LOCATION,
  [String]
  $ChangeLogMarker = $ENV:GCR_CHANGELOG_MARKER,
  [bool]
  $ChangeLogIsManaged = [Int]$ENV:GCR_MANAGE_CHANGELOG,
  [String]
  $DefaultBranchName = $ENV:GCR_DEFAULT_GIT_BRANCH
)

try {
  import-module ./app/modules/changelog
  import-module ./app/modules/fileHelpers
  import-module ./app/modules/github
  import-module ./app/modules/git
  import-module ./app/modules/logging

}
catch {
  Write-Error "Unable to import modules" -ErrorAction Stop
  exit 1
}

if (!($ENV:GITHUB_TOKEN)) {
  Write-Log -Level Error -Source 'entrypoint' -Message "No GITUB_TOKEN env var detected"
}
if (!($ENV:GITHUB_API_ROOT)) {
  Write-Log -Level INFO -Source 'entrypoint' -Message "GITHUB_API_ROOT has been set to api.github.com"
  $ENV:GITHUB_API_ROOT = 'api.github.com'
}
if (!($DefaultBranchName)){
  Write-Log -Level INFO -Source 'entrypoint' -Message "DefaultBranchName has been set to 'main', to override set env var: GFM_DEFAULT_GIT_BRANCH"
  $DefaultBranchName = 'main'
}

# Due to Chef-Workstation not having the latest cookstyle gem we hack around here
bash -c "curl -L https://omnitruck.chef.io/install.sh | bash -s -- -P chef"
$ENV:PATH = "/opt/chef/embedded/bin:"+$ENV:PATH
gem install cookstyle

$cookstyleVersionRaw = cookstyle --version
$cookstyleVersion = $cookstyleVersionRaw| Where-Object {$_ -like "cookstyle*"}
if (!($cookstyleVersionRaw)) {
  Write-Log -Level Error -Source 'entrypoint' -Message "Unable to find cookstyle"
}

$PullRequestBody = "Hey!`nI ran $CookstyleVersion against this repo and here are the results."
$PullRequestBody += "`nThis repo was selected due to the topics of $DestinationRepoTopicsCsv"
# Setup the git config first, if env vars are not supplied this will do nothing.
Set-GitConfig -gitName $GitName -gitEmail $GitEmail


Write-Log -Level Info -Source 'entrypoint' -Message "Finding all repositories in the destination"
$searchQuery = "org:$DestinationRepoOwner"

foreach ($topic in $DestinationRepoTopicsCsv.split(',')) {
  $searchQuery += " topic:$topic"
}
try {
  $DestinationRepositories = Get-GithubRepositorySearchResults -Query $searchQuery
}
catch {
  Write-Log -Level Error -Source 'entrypoint' -Message "Unable to find destination repositories for $searchQuery"
}

try {
  Write-Log -Level Info -Source 'entrypoint' -Message "Setting up file paths for $sourceRepoOwner/$sourceRepoName"
  $DestinationRepositoriesDiskLocation = 'destination-repos'
  Remove-PathIfExists $DestinationRepositoriesDiskLocation
  New-Item $DestinationRepositoriesDiskLocation -ItemType Directory
  $rootFolder = $pwd
}
catch {
  Write-Log -Level Error -Source 'entrypoint' -Message "Unable to setup file paths for $DestinationRepositoriesDiskLocation"
}
# Clone out each and every repository
foreach ($repository in $DestinationRepositories) {
  Set-Location $rootFolder
  Write-Log -Level Info -Source 'entrypoint' -Message "Starting processing on $($repository.name)"
  # Clone and setup folder tracking
  $repoFolder = Join-Path $DestinationRepositoriesDiskLocation $repository.name
  try {
    Write-Log -Level Info -Source 'entrypoint' -Message "Cloning $DestinationRepositoriesDiskLocation/$($repository.name)"
    New-GitClone -HttpUrl $repository.clone_url -Directory "$DestinationRepositoriesDiskLocation/$($repository.name)"
  }
  catch {
    Write-Log -Level Error -Source 'entrypoint' -Message "Unable to clone $sourceRepoOwner/$sourceRepoName"
  }

  try {
    $branchExists = Get-GithubBranch -repo $repository.name -owner $DestinationRepoOwner -branchFilterName $BranchName
    if ($branchExists) {
      Write-Log -Level INFO -Source 'entrypoint' -Message "Branch $branchName already exists, switching to it"
      Set-Location $repoFolder
      Select-GitBranch -BranchName $BranchName
      Set-Location $rootFolder
    }
  }
  catch {
    Write-Log -Level Error -Source 'entrypoint' -Message "Unable to check if branch $branchName already exists"
  }

  try {
    Write-Log -Level INFO -Source 'entrypoint' -Message "running cookstyle -a on $repoFolder"
    # Copy items into the folder
    Set-Location $repoFolder
    $CookstyleRaw = cookstyle -a --format json
    $CookstyleFixes = ConvertFrom-Json $CookstyleRaw
    $filesWithOffenses = $CookstyleFixes.files | Where-Object { $_.offenses }
    $changesMessage = "$cookstyleVersion Fixes"
    $pullRequestMessage = ''
    $changeLogMessage = ''
    foreach ($file in $filesWithOffenses) {
      # Only log files we actually changed
      if ($file.offenses.corrected -contains $true) {
        $changesMessage += "`n`nIssues found and resolved with: $($file.path)`n"
        $pullRequestMessage += "`n`n### Issues found and resolved with $($file.path)`n"
        foreach ($offense in $file.offenses | Where-Object { $_.corrected -eq $true }) {
          $changesMessage += "`n - $($offense.location.line):$($offense.location.column) $($offense.severity): $($offense.cop_name) - $($offense.message)"
          $pullRequestMessage += "`n - $($offense.location.line):$($offense.location.column) $($offense.severity): ``$($offense.cop_name)`` - $($offense.message)"
          $changeLogMessage += "- resolved cookstyle error: $($file.path):$($offense.location.line):$($offense.location.column) $($offense.severity): ``$($offense.cop_name)```n"
        }
      }
    }
    $filesChanged = Get-GitChangeCount
  }
  catch {
    Write-Log -Level Error -Source 'entrypoint' -Message "Error running cookstyle on $repoFolder"
  }
  if ($filesChanged -gt 0) {
    try {
      if (!($branchExists)) {
        Write-Log -Level INFO -Source 'entrypoint' -Message "Creating branch $BranchName as it does not already exist"
        New-GithubBranch -repo $repository.name -owner $DestinationRepoOwner -BranchName $BranchName -BranchFromName $DefaultBranchName
        Select-GitBranch -BranchName $BranchName
      }
    }
    catch {
      Write-Log -Level Error -Source 'entrypoint' -Message "Unable to create branch $BranchName"
    }
    if ($ChangeLogIsManaged) {
      Write-Log -Level INFO -Source 'entrypoint' -Message "Managing the changelog in $ChangeLogLocation with Marker of $ChangeLogMarker"
      Set-ChangeLog -ChangelogPath $ChangeLogLocation -ChangeLogMarker $ChangeLogMarker -ChangeLogEntry $changeLogMessage
    }

    # Commit the files that have changed
    try {
      Write-Log -Level INFO -Source 'entrypoint' -Message "Commiting standardised files and pushing to remote if changed"
      New-CommitAndPushIfChanged -CommitMessage ($changesMessage.replace('"','').replace('#','').replace('`','').replace('(','').replace(')','')) -push
    }
    catch {
      Write-Log -Level ERROR -Source 'entrypoint' -Message "Unable to commit standardised files and push to remote if changed"
    }
    try {
      Write-Log -Level INFO -Source 'entrypoint' -Message "Opening Pull Request $PullRequestTitle with body of $PullRequestBody"
      New-GithubPullRequest -owner $DestinationRepoOwner -Repo $repository.name -Head "$($DestinationRepoOwner):$($BranchName)" -base $DefaultBranchName -title $PullRequestTitle -body "$PullRequestBody`n`n## Changes$pullRequestMessage"
    }
    catch {
      Write-Log -Level ERROR -Source 'entrypoint' -Message "Unable to open Pull Request $PullRequestTitle with body of $PullRequestBody"
    }
  }
  else {
    Write-Log -Level INFO -Source 'entrypoint' -Message "No file changes to process"
  }
}

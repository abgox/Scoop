<#
.SYNOPSIS
    Updates manifests and pushes them or creates pull-requests.
.DESCRIPTION
    Updates manifests and pushes them directly to the origin branch or creates pull-requests for upstream.
.PARAMETER Upstream
    Upstream repository with the target branch.
    Must be in format '<user>/<repo>:<branch>'
.PARAMETER OriginBranch
    Origin (local) branch name.
.PARAMETER App
    Manifest name to search.
    Placeholders are supported.
.PARAMETER CommitMessageFormat
    The format of the commit message.
    <app> will be replaced with the file name of manifest.
    <version> will be replaced with the version of the latest manifest.
.PARAMETER Dir
    The directory where to search for manifests.
.PARAMETER Push
    Push updates directly to 'origin branch'.
.PARAMETER Request
    Create pull-requests on 'upstream branch' for each update.
.PARAMETER Help
    Print help to console.
.PARAMETER SpecialSnowflakes
    An array of manifests, which should be updated all the time. (-ForceUpdate parameter to checkver)
.PARAMETER SkipUpdated
    Updated manifests will not be shown.
.PARAMETER ThrowError
    Throw error as exception instead of just printing it.
.EXAMPLE
    PS BUCKETROOT > .\bin\auto-pr.ps1 'someUsername/repository:branch' -Request
.EXAMPLE
    PS BUCKETROOT > .\bin\auto-pr.ps1 -Push
    Update all manifests inside 'bucket/' directory.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript( {
        if (!($_ -match '^(.*)\/(.*):(.*)$')) {
            throw 'Upstream must be in this format: <user>/<repo>:<branch>'
        }
        $true
    })]
    [String] $Upstream,
    [String] $OriginBranch = 'master',
    [String] $App = '*',
    [String] $CommitMessageFormat = '<app>: Update to version <version>',
    [ValidateScript( {
        if (!(Test-Path $_ -Type Container)) {
            throw "$_ is not a directory!"
        } else {
            $true
        }
    })]
    [String] $Dir,
    [Switch] $Push,
    [Switch] $Request,
    [Switch] $Help,
    [string[]] $SpecialSnowflakes,
    [Switch] $SkipUpdated,
    [Switch] $ThrowError
)

. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\json.ps1"

if ($App -ne '*' -and (Test-Path $App -PathType Leaf)) {
    $Dir = Split-Path $App
} elseif ($Dir) {
    $Dir = Convert-Path $Dir
} else {
    throw "'-Dir' parameter required if '-App' is not a filepath!"
}

if ((!$Push -and !$Request) -or $Help) {
    Write-Host @'
Usage: auto-pr.ps1 [OPTION]

Mandatory options:
  -p,  -push                       push updates directly to 'origin branch'
  -r,  -request                    create pull-requests on 'upstream branch' for each update

Optional options:
  -u,  -upstream                   upstream repository with target branch
  -o,  -originbranch               origin (local) branch name
  -h,  -help
'@
    exit 0
}

function pull_requests($json, [String] $app, [String] $upstream, [String] $manifest, [String] $commitMessage) {
    $version = $json.version
    $homepage = $json.homepage
    $branch = "manifest/$app-$version"
    $upstreamRepo, $upstreamBranch = $upstream -split ':', 2

    git checkout $OriginBranch
    Write-Host "git rev-parse --verify $branch" -ForegroundColor Green
    git rev-parse --verify $branch

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Skipping update $app ($version) ..." -ForegroundColor Yellow
        return
    }

    Write-Host "Creating update $app ($version) ..." -ForegroundColor DarkCyan
    git checkout -B $branch
    git add $manifest
    git commit -m $commitMessage
    Write-Host "Pushing update $app ($version) ..." -ForegroundColor DarkCyan
    git push origin $branch

    if ($LASTEXITCODE -gt 0) {
        error "Push failed! (git push origin $branch)"
        git reset --hard
        return
    }

    Start-Sleep 1
    Write-Host "Pull-Request update $app ($version) ..." -ForegroundColor DarkCyan
    Write-Host "gh pr create --repo '$upstreamRepo' --base '$upstreamBranch' --head '$branch' --title '<commitMessage>' --body '<msg>'" -ForegroundColor Green

    $msg = @"
$commitMessage

Hello lovely humans,
a new version of [$app]($homepage) is available.

| State       | Update :rocket: |
| :---------- | :-------------- |
| New version | $version        |
"@

    gh pr create --repo "$upstreamRepo" --base "$upstreamBranch" --head "$branch" --title "$commitMessage" --body "$msg"

    if ($LASTEXITCODE -gt 0) {
        git reset --hard
        abort "Pull Request failed! (gh pr create --repo '$upstreamRepo' --base '$upstreamBranch' --head '$branch' --title '<commitMessage>' --body '<msg>')"
    }
}

Write-Host 'Updating ...' -ForegroundColor DarkCyan
if ($Push) {
    git pull origin $OriginBranch
    git checkout $OriginBranch
} else {
    git pull upstream $OriginBranch
    git push origin $OriginBranch
}

. "$PSScriptRoot\checkver.ps1" -App $App -Dir $Dir -Update -SkipUpdated:$SkipUpdated -ThrowError:$ThrowError
if ($SpecialSnowflakes) {
    Write-Host "Forcing update on our special snowflakes: $($SpecialSnowflakes -join ',')" -ForegroundColor DarkCyan
    $SpecialSnowflakes | ForEach-Object {
        . "$PSScriptRoot\checkver.ps1" $_ -Dir $Dir -ForceUpdate -ThrowError:$ThrowError
    }
}

git diff --name-only HEAD | ForEach-Object {
    $manifest = $_
    if (!$manifest.EndsWith('.json')) {
        return
    }

    $app = ([System.IO.Path]::GetFileNameWithoutExtension($manifest))
    $json = parse_json $manifest
    if (!$json.version) {
        error "Invalid manifest: $manifest ..."
        return
    }
    $version = $json.version
    $CommitMessage = $CommitMessageFormat -replace '<app>',$app -replace '<version>',$version
    if ($Push) {
        Write-Host "Creating update $app ($version) ..." -ForegroundColor DarkCyan
        git add $manifest

        # detect if file was staged, because it's not when only LF or CRLF have changed
        $status = git status --porcelain -uno
        $status = $status | Where-Object { $_ -match "M\s{2}.*$app.json" }
        if ($status -and $status.StartsWith('M  ') -and $status.EndsWith("$app.json")) {
            git commit -m $commitMessage
        } else {
            Write-Host "Skipping $app because only LF/CRLF changes were detected ..." -ForegroundColor Yellow
        }
    } else {
        pull_requests $json $app $Upstream $manifest $CommitMessage
    }
}

if ($Push) {
    Write-Host 'Pushing updates ...' -ForegroundColor DarkCyan
    git push origin $OriginBranch
} else {
    Write-Host "Returning to $OriginBranch branch and removing unstaged files ..." -ForegroundColor DarkCyan
    git checkout -f $OriginBranch
}

git reset --hard

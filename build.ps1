
function Log()
{
    [CmdletBinding()]
    param(
        $message
    )
    Write-Information $message -InformationAction Continue
}

function ParamOrDefault {
    [CmdletBinding()]
    param(
        $value,
        $default
    )
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $default
    }
    return $value
}

function Step()
{
    param(
        $name,
        [ScriptBlock] $action
    )
    
    Log ""
    Log  "============= Step '$name' ============="
    Log  ""
    $LastExitCode = 0
    & $action
    if($LastExitCode -ne 0)
    {
        throw "Step '$name' exited with code '$LastExitCode'"
    }
}

function SelectSolution()
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        $repoDir = $PSScriptRoot
    )

    $result = ""
    $directory = Get-Item $repoDir
    Log "No solution was provided. Search for a solution file in $($directory.FullName)"

    $solutions = @(Get-ChildItem $repoDir -recurse -File "*.sln")
    
    if($solutions.Length -eq 0)
    {
        throw "No solution found."
    }
    elseif($solutions.Length -eq 1)
    {
        Log "Found exactly one solution file."
        $result = $solutions[0].FullName;
    }
    else {
        Log "Multiple candidates found. Use conventions. Try to select a solution called $expectedSolutionFile."

        $expectedSolutionFile = "$($directory.Name).sln"
        
        $solutions = @(Get-ChildItem $repoDir -recurse -File $expectedSolutionFile)

        if($solutions.Length -eq 0)
        {
            throw "No solution named $expectedSolutionFile found. Please provide the solution path explicitely."
        }
        elseif($solutions.Length -eq 1)
        {
            $result = $solutions[0].FullName;
        }
        else
        {
            throw "Multiple solution named $expectedSolutionFile found. Please provide the solution path explicitely."
        }
    }
    
    Log "Select solution '$result'"
    $result
}

function Build()
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        $repoDir = $PSScriptRoot,
        [Parameter(Mandatory=$false)]
        [string] $configuration = "Release",

        [Parameter(Mandatory=$false)]
        $buildDir = "$repoDir\build",
        [Parameter(Mandatory=$false)]
        $buildProj = "$buildDir\Build.csproj",

        [Parameter(Mandatory=$false)]
        $buildToolsDir = "$buildDir\tools",
        [Parameter(Mandatory=$false)]
        $artifactsOutputDir = "$buildDir\artifacts",
        [Parameter(Mandatory=$false)]
        $solutionPath = $null,
        [Parameter(Mandatory=$false)]
        [string] $gitVersionVersion = "4.0.0-beta0012",
        
        [Parameter(Mandatory=$false)]
        [string] $nugetPackagesVersion = $null,
        [Parameter(Mandatory=$false)]
        [string] $assemblyVersion = $null,
        [Parameter(Mandatory=$false)]
        [string] $informationalVersion = $null
    )

    $ErrorActionPreference = "Stop"
    # VersionPrefix, VersionSuffix, PackageVersion, InformationalVersion, AssemblyVersion and FileVersion

    if(!$solutionPath)
    {
        $solutionPath = Step "Auto Discovery Solution" {
            SelectSolution $repoDir
        }
    }
    

    Step "Clean Artifacts Folder" {
        Log "Delete $artifactsOutputDir"
        Get-ChildItem $artifactsOutputDir -ErrorAction Ignore | Remove-Item -Recurse
    }

    Step "Restore" { 
        dotnet restore `
            --packages $buildToolsDir `
            /p:GitVersion_Version=$gitVersionVersion $buildProj
    }
    
    $gitVersionOutput = Step "GitVersion" {
        [string] $out = . $buildToolsDir\gitversion.commandline\$gitVersionVersion\tools\GitVersion.exe
        . $buildToolsDir\gitversion.commandline\$gitVersionVersion\tools\GitVersion.exe /output buildserver
        ConvertFrom-Json $out
    }

    $nugetPackagesVersion = ParamOrDefault $nugetPackagesVersion $gitVersionOutput.NuGetVersionV2
    $assemblyVersion =  ParamOrDefault $assemblyVersion $gitVersionOutput.AssemblySemVer
    $informationalVersion = ParamOrDefault $gitVersionOutput.InformationalVersion

    Log "nugetPackagesVersion = $nugetPackagesVersion"
    Log "assemblyVersion = $assemblyVersion"
    Log "informationalVersion = $informationalVersion"
    
     Step "Build" {
        dotnet build $solutionPath `
            --configuration $configuration `
            /p:Version=$assemblyVersion `
            /p:InformationalVersion=$informationalVersion `
            /p:AssemblyVersion=$assemblyVersion `
            /p:FileVersion=$assemblyVersion
    }

    Step "Test" {
        dotnet vstest --Parallel (Get-ChildItem -recurse -File "*.Tests.dll" | Where-Object { $_.FullName -match "\\bin\\$configuration\\?" })
    }

    Step "NuGet Pack" {
        $nugetPackagesOutputDir = "$artifactsOutputDir\nuget"
        Log "Generate nuget packages in $nugetPackagesOutputDir"
        dotnet pack  --configuration $configuration /p:PackageVersion=$nugetPackagesVersion  --no-build --no-restore --output $nugetPackagesOutputDir $solutionPath
    }
}


Build @args
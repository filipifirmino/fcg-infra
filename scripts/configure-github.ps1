param(
    [string]$Owner = "filipifirmino",
    [string[]]$Repositories = @("fcg-users-api", "fcg-catalog-api"),
    [string]$AwsProfile = "fcg",
    [string]$Region = "us-east-1",
    [string]$RoleName = "fcg-github-actions"
)

$ErrorActionPreference = "Stop"

$roleArn = aws iam get-role --role-name $RoleName --profile $AwsProfile --query Role.Arn --output text

foreach ($repository in $Repositories) {
    $target = "$Owner/$repository"
    gh variable set AWS_ROLE_ARN --body $roleArn --repo $target
    gh variable set AWS_REGION --body $Region --repo $target
    gh api --method PUT "repos/$target/environments/production" | Out-Null
    Write-Host "$target configurado (AWS_ROLE_ARN, AWS_REGION, environment production)"
}

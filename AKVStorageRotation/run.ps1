param($eventGridEvent, $TriggerMetadata)

function RegenerateKey($keyId, $providerAddress, $tagType){
    Write-Host "Regenerating key. Id: $keyId Resource Id: $providerAddress"
    
    $storageAccountName = ($providerAddress -split '/')[8]
    $resourceGroupName = ($providerAddress -split '/')[4]
    
    #Regenerate key 
    New-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName -KeyName $keyId
    if ($tagType -eq "ConnectionString")
    {
        $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName).Value[0]
        $newKeyValue = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$storageAccountKey;EndpointSuffix=core.windows.net"
    }
    else
    {
        $newKeyValue = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName|where KeyName -eq $keyId).value
    }

    return $newKeyValue
}

function AddSecretToKeyVault($keyVaultName,$secretName,$newAccessKeyValue,$expiryDate,$tags){
    
    $secretvalue = ConvertTo-SecureString "$newAccessKeyValue" -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -SecretValue $secretvalue -Tag $tags -Expires $expiryDate

}

function GetAlternateCredentialId($keyId){
    $validCredentialIdsRegEx = 'key[1-2]'
    
    If($keyId -NotMatch $validCredentialIdsRegEx){
        throw "Invalid credential id: $keyId. Credential id must follow this pattern:$validCredentialIdsRegEx"
    }
    If($keyId -eq 'key1'){
        return "key2"
    }
    Else{
        return "key1"
    }
}

function RotateSecret($keyVaultName,$secretName){
    #Retrieve Secret
    $secret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName)
    Write-Host "Secret Retrieved"
    
    #Retrieve Secret Info
    $validityPeriodDays = $secret.Tags["ValidityPeriodDays"]
    $credentialId =  $secret.Tags["CredentialId"]
    $providerAddress = $secret.Tags["ProviderAddress"]
    $secretType = $secret.Tags["SecretType"]
    
    Write-Host "Secret Info Retrieved"
    Write-Host "Validity Period: $validityPeriodDays"
    Write-Host "Credential Id: $credentialId"
    Write-Host "Provider Address: $providerAddress"
    Write-Host "Secret Type: $secretType"

    #Get Credential Id to rotate - alternate credential
    $alternateCredentialId = GetAlternateCredentialId $credentialId
    Write-Host "Alternate credential id: $alternateCredentialId"

    #Regenerate alternate access key in provider
    $newAccessKeyValue = (RegenerateKey $alternateCredentialId $providerAddress $secretType)[-1]
    Write-Host "Access key regenerated. Access Key Id: $alternateCredentialId Resource Id: $providerAddress"

    #Add new access key to Key Vault
    $newSecretVersionTags = @{}
    $newSecretVersionTags.ValidityPeriodDays = $validityPeriodDays
    $newSecretVersionTags.CredentialId=$alternateCredentialId
    $newSecretVersionTags.ProviderAddress = $providerAddress
    $newSecretVersionTags.SecretType = $secretType

    $expiryDate = (Get-Date).AddDays([int]$validityPeriodDays).ToUniversalTime()
    AddSecretToKeyVault $keyVaultName $secretName $newAccessKeyValue $expiryDate $newSecretVersionTags

    Write-Host "New access key added to Key Vault. Secret Name: $secretName"
}

# Make sure to pass hashtables to Out-String so they're logged correctly
$eventGridEvent | ConvertTo-Json | Write-Host

$secretName = $eventGridEvent.subject
$keyVaultName = $eventGridEvent.data.VaultName
Write-Host "Key Vault Name: $keyVaultName"
Write-Host "Secret Name: $secretName"

#Rotate secret
Write-Host "Rotation started."
RotateSecret $keyVaultName $secretName
Write-Host "Secret Rotated Successfully"


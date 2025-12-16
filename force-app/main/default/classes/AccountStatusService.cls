/**
 * @description Service class that handles updates to related Contacts when an Account's status changes.
 * This class follows Salesforce best practices for bulkification and separation of concerns.
 */
public with sharing class AccountStatusService {
    
    /**
     * @description Updates related Contacts when Account status changes.
     * Sets the Contact's Account_Status__c field to match the Account's status
     * and updates the Status_Last_Modified__c timestamp.
     * @param newAccounts List of Account records with new values
     * @param oldAccountsMap Map of Account Id to old Account record values
     */
    public static void updateContactsOnStatusChange(List<Account> newAccounts, Map<Id, Account> oldAccountsMap) {
        Set<Id> accountIdsWithStatusChange = getAccountsWithStatusChange(newAccounts, oldAccountsMap);
        
        if (accountIdsWithStatusChange.isEmpty()) {
            return;
        }
        
        List<Contact> contactsToUpdate = getContactsForAccounts(accountIdsWithStatusChange);
        
        if (contactsToUpdate.isEmpty()) {
            return;
        }
        
        Map<Id, String> accountStatusMap = buildAccountStatusMap(newAccounts, accountIdsWithStatusChange);
        updateContactStatuses(contactsToUpdate, accountStatusMap);
        
        if (!contactsToUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(contactsToUpdate, false);
            handleSaveResults(results, contactsToUpdate);
        }
    }
    
    /**
     * @description Identifies Account Ids where the status field has changed.
     * @param newAccounts List of Account records with new values
     * @param oldAccountsMap Map of Account Id to old Account record values
     * @return Set of Account Ids where status changed
     */
    private static Set<Id> getAccountsWithStatusChange(List<Account> newAccounts, Map<Id, Account> oldAccountsMap) {
        Set<Id> changedAccountIds = new Set<Id>();
        
        for (Account newAccount : newAccounts) {
            Account oldAccount = oldAccountsMap.get(newAccount.Id);
            
            if (oldAccount != null && hasStatusChanged(newAccount, oldAccount)) {
                changedAccountIds.add(newAccount.Id);
            }
        }
        
        return changedAccountIds;
    }
    
    /**
     * @description Checks if the Account status field has changed.
     * @param newAccount Account record with new values
     * @param oldAccount Account record with old values
     * @return True if status changed, false otherwise
     */
    private static Boolean hasStatusChanged(Account newAccount, Account oldAccount) {
        return newAccount.Status__c != oldAccount.Status__c;
    }
    
    /**
     * @description Queries Contacts related to the specified Accounts.
     * @param accountIds Set of Account Ids to query contacts for
     * @return List of Contact records related to the accounts
     */
    private static List<Contact> getContactsForAccounts(Set<Id> accountIds) {
        return [
            SELECT Id, AccountId, Account_Status__c, Status_Last_Modified__c
            FROM Contact
            WHERE AccountId IN :accountIds
            WITH SECURITY_ENFORCED
        ];
    }
    
    /**
     * @description Builds a map of Account Id to new status value.
     * @param newAccounts List of Account records
     * @param accountIds Set of Account Ids to include in the map
     * @return Map of Account Id to status value
     */
    private static Map<Id, String> buildAccountStatusMap(List<Account> newAccounts, Set<Id> accountIds) {
        Map<Id, String> statusMap = new Map<Id, String>();
        
        for (Account acc : newAccounts) {
            if (accountIds.contains(acc.Id)) {
                statusMap.put(acc.Id, acc.Status__c);
            }
        }
        
        return statusMap;
    }
    
    /**
     * @description Updates Contact records with the new Account status.
     * @param contacts List of Contact records to update
     * @param accountStatusMap Map of Account Id to new status value
     */
    private static void updateContactStatuses(List<Contact> contacts, Map<Id, String> accountStatusMap) {
        Datetime currentTime = Datetime.now();
        
        for (Contact con : contacts) {
            String newStatus = accountStatusMap.get(con.AccountId);
            if (newStatus != null) {
                con.Account_Status__c = newStatus;
                con.Status_Last_Modified__c = currentTime;
            }
        }
    }
    
    /**
     * @description Handles Database.SaveResult array and logs any errors.
     * @param results Array of SaveResult from Database.update
     * @param contacts List of Contact records that were updated
     */
    private static void handleSaveResults(Database.SaveResult[] results, List<Contact> contacts) {
        List<String> errorMessages = new List<String>();
        
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    String errorMsg = 'Error updating Contact ' + contacts[i].Id + ': ' + 
                                     err.getStatusCode() + ' - ' + err.getMessage();
                    errorMessages.add(errorMsg);
                    System.debug(LoggingLevel.ERROR, errorMsg);
                }
            }
        }
        
        if (!errorMessages.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'AccountStatusService encountered ' + 
                        errorMessages.size() + ' errors while updating contacts.');
        }
    }
}

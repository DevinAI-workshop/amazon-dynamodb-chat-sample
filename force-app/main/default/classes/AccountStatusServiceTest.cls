/**
 * @description Test class for AccountStatusService.
 * Provides comprehensive test coverage for Account status change handling.
 */
@isTest
private class AccountStatusServiceTest {
    
    private static final String STATUS_ACTIVE = 'Active';
    private static final String STATUS_INACTIVE = 'Inactive';
    private static final String STATUS_PENDING = 'Pending';
    
    /**
     * @description Creates test Account records.
     * @param count Number of accounts to create
     * @param status Initial status value
     * @return List of inserted Account records
     */
    private static List<Account> createTestAccounts(Integer count, String status) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name = 'Test Account ' + i,
                Status__c = status
            ));
        }
        insert accounts;
        return accounts;
    }
    
    /**
     * @description Creates test Contact records for given accounts.
     * @param accounts List of Account records to create contacts for
     * @param contactsPerAccount Number of contacts per account
     * @return List of inserted Contact records
     */
    private static List<Contact> createTestContacts(List<Account> accounts, Integer contactsPerAccount) {
        List<Contact> contacts = new List<Contact>();
        for (Account acc : accounts) {
            for (Integer i = 0; i < contactsPerAccount; i++) {
                contacts.add(new Contact(
                    FirstName = 'Test',
                    LastName = 'Contact ' + i,
                    AccountId = acc.Id,
                    Account_Status__c = acc.Status__c
                ));
            }
        }
        insert contacts;
        return contacts;
    }
    
    /**
     * @description Tests that contacts are updated when account status changes.
     */
    @isTest
    static void testContactsUpdatedOnStatusChange() {
        List<Account> accounts = createTestAccounts(1, STATUS_ACTIVE);
        List<Contact> contacts = createTestContacts(accounts, 3);
        
        Test.startTest();
        accounts[0].Status__c = STATUS_INACTIVE;
        update accounts;
        Test.stopTest();
        
        List<Contact> updatedContacts = [
            SELECT Id, Account_Status__c, Status_Last_Modified__c 
            FROM Contact 
            WHERE AccountId = :accounts[0].Id
        ];
        
        System.assertEquals(3, updatedContacts.size(), 'Should have 3 contacts');
        for (Contact con : updatedContacts) {
            System.assertEquals(STATUS_INACTIVE, con.Account_Status__c, 
                'Contact status should be updated to Inactive');
            System.assertNotEquals(null, con.Status_Last_Modified__c, 
                'Status last modified should be set');
        }
    }
    
    /**
     * @description Tests that contacts are not updated when account status does not change.
     */
    @isTest
    static void testContactsNotUpdatedWhenStatusUnchanged() {
        List<Account> accounts = createTestAccounts(1, STATUS_ACTIVE);
        List<Contact> contacts = createTestContacts(accounts, 2);
        
        Datetime originalModifiedTime = contacts[0].Status_Last_Modified__c;
        
        Test.startTest();
        accounts[0].Name = 'Updated Account Name';
        update accounts;
        Test.stopTest();
        
        List<Contact> updatedContacts = [
            SELECT Id, Account_Status__c, Status_Last_Modified__c 
            FROM Contact 
            WHERE AccountId = :accounts[0].Id
        ];
        
        for (Contact con : updatedContacts) {
            System.assertEquals(STATUS_ACTIVE, con.Account_Status__c, 
                'Contact status should remain Active');
        }
    }
    
    /**
     * @description Tests bulk update of multiple accounts with status changes.
     */
    @isTest
    static void testBulkAccountStatusChange() {
        List<Account> accounts = createTestAccounts(100, STATUS_ACTIVE);
        List<Contact> contacts = createTestContacts(accounts, 2);
        
        Test.startTest();
        for (Account acc : accounts) {
            acc.Status__c = STATUS_PENDING;
        }
        update accounts;
        Test.stopTest();
        
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();
        List<Contact> updatedContacts = [
            SELECT Id, Account_Status__c, Status_Last_Modified__c 
            FROM Contact 
            WHERE AccountId IN :accountIds
        ];
        
        System.assertEquals(200, updatedContacts.size(), 'Should have 200 contacts');
        for (Contact con : updatedContacts) {
            System.assertEquals(STATUS_PENDING, con.Account_Status__c, 
                'Contact status should be updated to Pending');
            System.assertNotEquals(null, con.Status_Last_Modified__c, 
                'Status last modified should be set');
        }
    }
    
    /**
     * @description Tests that accounts without contacts do not cause errors.
     */
    @isTest
    static void testAccountWithNoContacts() {
        List<Account> accounts = createTestAccounts(1, STATUS_ACTIVE);
        
        Test.startTest();
        accounts[0].Status__c = STATUS_INACTIVE;
        update accounts;
        Test.stopTest();
        
        List<Contact> contacts = [
            SELECT Id FROM Contact WHERE AccountId = :accounts[0].Id
        ];
        System.assertEquals(0, contacts.size(), 'Should have no contacts');
    }
    
    /**
     * @description Tests mixed scenario where some accounts have status changes and others do not.
     */
    @isTest
    static void testMixedStatusChanges() {
        List<Account> accountsWithChange = createTestAccounts(2, STATUS_ACTIVE);
        List<Account> accountsWithoutChange = createTestAccounts(2, STATUS_INACTIVE);
        
        List<Contact> contactsWithChange = createTestContacts(accountsWithChange, 2);
        List<Contact> contactsWithoutChange = createTestContacts(accountsWithoutChange, 2);
        
        Test.startTest();
        for (Account acc : accountsWithChange) {
            acc.Status__c = STATUS_PENDING;
        }
        for (Account acc : accountsWithoutChange) {
            acc.Name = acc.Name + ' Updated';
        }
        
        List<Account> allAccounts = new List<Account>();
        allAccounts.addAll(accountsWithChange);
        allAccounts.addAll(accountsWithoutChange);
        update allAccounts;
        Test.stopTest();
        
        Set<Id> changedAccountIds = new Map<Id, Account>(accountsWithChange).keySet();
        List<Contact> updatedContacts = [
            SELECT Id, Account_Status__c 
            FROM Contact 
            WHERE AccountId IN :changedAccountIds
        ];
        
        for (Contact con : updatedContacts) {
            System.assertEquals(STATUS_PENDING, con.Account_Status__c, 
                'Contact status should be updated to Pending');
        }
        
        Set<Id> unchangedAccountIds = new Map<Id, Account>(accountsWithoutChange).keySet();
        List<Contact> unchangedContacts = [
            SELECT Id, Account_Status__c 
            FROM Contact 
            WHERE AccountId IN :unchangedAccountIds
        ];
        
        for (Contact con : unchangedContacts) {
            System.assertEquals(STATUS_INACTIVE, con.Account_Status__c, 
                'Contact status should remain Inactive');
        }
    }
    
    /**
     * @description Tests direct service method call without trigger context.
     */
    @isTest
    static void testDirectServiceCall() {
        List<Account> accounts = createTestAccounts(1, STATUS_ACTIVE);
        List<Contact> contacts = createTestContacts(accounts, 2);
        
        Map<Id, Account> oldAccountsMap = new Map<Id, Account>();
        for (Account acc : accounts) {
            oldAccountsMap.put(acc.Id, acc.clone(true, true, true, true));
        }
        
        accounts[0].Status__c = STATUS_INACTIVE;
        
        Test.startTest();
        AccountStatusService.updateContactsOnStatusChange(accounts, oldAccountsMap);
        Test.stopTest();
        
        List<Contact> updatedContacts = [
            SELECT Id, Account_Status__c 
            FROM Contact 
            WHERE AccountId = :accounts[0].Id
        ];
        
        for (Contact con : updatedContacts) {
            System.assertEquals(STATUS_INACTIVE, con.Account_Status__c, 
                'Contact status should be updated to Inactive');
        }
    }
}

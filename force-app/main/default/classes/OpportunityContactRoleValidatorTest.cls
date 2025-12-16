@isTest
private class OpportunityContactRoleValidatorTest {
    
    @TestSetup
    static void setupTestData() {
        Account testAccount = new Account(Name = 'Test Account');
        insert testAccount;
        
        Contact testContact = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            AccountId = testAccount.Id
        );
        insert testContact;
    }
    
    @isTest
    static void testClosedWonWithContactRole_ShouldSucceed() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        Contact testContact = [SELECT Id FROM Contact LIMIT 1];
        
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = testAccount.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        
        OpportunityContactRole contactRole = new OpportunityContactRole(
            OpportunityId = opp.Id,
            ContactId = testContact.Id,
            Role = 'Decision Maker'
        );
        insert contactRole;
        
        Test.startTest();
        opp.StageName = 'Closed Won';
        Database.SaveResult result = Database.update(opp, false);
        Test.stopTest();
        
        System.assert(result.isSuccess(), 'Opportunity should be updated successfully when Contact Role exists');
    }
    
    @isTest
    static void testClosedWonWithoutContactRole_ShouldFail() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity Without Contact Role',
            AccountId = testAccount.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        
        Test.startTest();
        opp.StageName = 'Closed Won';
        Database.SaveResult result = Database.update(opp, false);
        Test.stopTest();
        
        System.assert(!result.isSuccess(), 'Opportunity update should fail without Contact Role');
        System.assert(result.getErrors()[0].getMessage().contains('Contact Role'), 
            'Error message should mention Contact Role');
    }
    
    @isTest
    static void testOtherStageWithoutContactRole_ShouldSucceed() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity Other Stage',
            AccountId = testAccount.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        
        Test.startTest();
        opp.StageName = 'Qualification';
        Database.SaveResult result = Database.update(opp, false);
        Test.stopTest();
        
        System.assert(result.isSuccess(), 'Opportunity should be updated to non-Closed Won stage without Contact Role');
    }
    
    @isTest
    static void testAlreadyClosedWonUpdate_ShouldSucceed() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        Contact testContact = [SELECT Id FROM Contact LIMIT 1];
        
        Opportunity opp = new Opportunity(
            Name = 'Test Already Closed Won',
            AccountId = testAccount.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        
        OpportunityContactRole contactRole = new OpportunityContactRole(
            OpportunityId = opp.Id,
            ContactId = testContact.Id,
            Role = 'Decision Maker'
        );
        insert contactRole;
        
        opp.StageName = 'Closed Won';
        update opp;
        
        Test.startTest();
        opp.Description = 'Updated description';
        Database.SaveResult result = Database.update(opp, false);
        Test.stopTest();
        
        System.assert(result.isSuccess(), 'Already Closed Won opportunity should allow other field updates');
    }
    
    @isTest
    static void testBulkUpdate_MixedScenarios() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        Contact testContact = [SELECT Id FROM Contact LIMIT 1];
        
        List<Opportunity> opportunities = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opportunities.add(new Opportunity(
                Name = 'Bulk Test Opportunity ' + i,
                AccountId = testAccount.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ));
        }
        insert opportunities;
        
        OpportunityContactRole contactRole = new OpportunityContactRole(
            OpportunityId = opportunities[0].Id,
            ContactId = testContact.Id,
            Role = 'Decision Maker'
        );
        insert contactRole;
        
        Test.startTest();
        for (Opportunity opp : opportunities) {
            opp.StageName = 'Closed Won';
        }
        List<Database.SaveResult> results = Database.update(opportunities, false);
        Test.stopTest();
        
        System.assert(results[0].isSuccess(), 'First opportunity with Contact Role should succeed');
        for (Integer i = 1; i < results.size(); i++) {
            System.assert(!results[i].isSuccess(), 'Opportunities without Contact Role should fail');
        }
    }
}

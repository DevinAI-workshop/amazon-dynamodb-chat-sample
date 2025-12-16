public with sharing class OpportunityContactRoleValidator {
    
    private static final String CLOSED_WON_STAGE = 'Closed Won';
    private static final String ERROR_MESSAGE = 'Cannot mark Opportunity as Closed Won without at least one Contact Role. Please add a Contact Role before closing this Opportunity.';
    
    public static void validateContactRoleExists(List<Opportunity> newOpportunities, Map<Id, Opportunity> oldOpportunityMap) {
        Set<Id> opportunitiesToValidate = new Set<Id>();
        
        for (Opportunity opp : newOpportunities) {
            Opportunity oldOpp = oldOpportunityMap.get(opp.Id);
            if (isBeingMarkedClosedWon(opp, oldOpp)) {
                opportunitiesToValidate.add(opp.Id);
            }
        }
        
        if (opportunitiesToValidate.isEmpty()) {
            return;
        }
        
        Map<Id, Integer> contactRoleCountByOpportunity = getContactRoleCountByOpportunity(opportunitiesToValidate);
        
        for (Opportunity opp : newOpportunities) {
            if (opportunitiesToValidate.contains(opp.Id)) {
                Integer contactRoleCount = contactRoleCountByOpportunity.get(opp.Id);
                if (contactRoleCount == null || contactRoleCount == 0) {
                    opp.addError(ERROR_MESSAGE);
                }
            }
        }
    }
    
    private static Boolean isBeingMarkedClosedWon(Opportunity newOpp, Opportunity oldOpp) {
        return newOpp.StageName == CLOSED_WON_STAGE && oldOpp.StageName != CLOSED_WON_STAGE;
    }
    
    private static Map<Id, Integer> getContactRoleCountByOpportunity(Set<Id> opportunityIds) {
        Map<Id, Integer> contactRoleCountMap = new Map<Id, Integer>();
        
        for (Id oppId : opportunityIds) {
            contactRoleCountMap.put(oppId, 0);
        }
        
        List<AggregateResult> results = [
            SELECT OpportunityId, COUNT(Id) roleCount
            FROM OpportunityContactRole
            WHERE OpportunityId IN :opportunityIds
            GROUP BY OpportunityId
        ];
        
        for (AggregateResult result : results) {
            Id opportunityId = (Id) result.get('OpportunityId');
            Integer roleCount = (Integer) result.get('roleCount');
            contactRoleCountMap.put(opportunityId, roleCount);
        }
        
        return contactRoleCountMap;
    }
}

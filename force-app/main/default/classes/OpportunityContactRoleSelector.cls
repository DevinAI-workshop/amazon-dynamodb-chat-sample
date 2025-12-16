public with sharing class OpportunityContactRoleSelector {
    
    public static Map<Id, Integer> getContactRoleCountByOpportunityIds(Set<Id> opportunityIds) {
        Map<Id, Integer> contactRoleCountMap = new Map<Id, Integer>();
        
        for (Id oppId : opportunityIds) {
            contactRoleCountMap.put(oppId, 0);
        }
        
        if (opportunityIds.isEmpty()) {
            return contactRoleCountMap;
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

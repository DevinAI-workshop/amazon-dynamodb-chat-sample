trigger OpportunityTrigger on Opportunity (before update) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        OpportunityContactRoleValidator.validateContactRoleExists(Trigger.new, Trigger.oldMap);
    }
}

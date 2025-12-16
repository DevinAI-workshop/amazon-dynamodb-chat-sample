/**
 * @description Trigger on Account object that handles status change events.
 * Delegates processing to AccountStatusService for updating related Contacts.
 */
trigger AccountTrigger on Account (after update) {
    
    if (Trigger.isAfter && Trigger.isUpdate) {
        AccountStatusService.updateContactsOnStatusChange(Trigger.new, Trigger.oldMap);
    }
}

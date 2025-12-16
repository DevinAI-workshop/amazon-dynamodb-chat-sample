# -*- coding: utf-8 -*-
import logging
import os
from datetime import datetime

import boto3
from boto3.dynamodb.conditions import Key

logging.basicConfig(format='%(levelname)s:%(message)s', level=logging.INFO)

# TTL options in seconds
TTL_OPTIONS = {
    '1min': 60,
    '5min': 300,
    '24hr': 86400,
    'never': None
}


def create_connection(table_name):
    ddb = None
    if os.getenv('API_ENDPOINT') != 'localhost':
        ddb = boto3.resource('dynamodb')
    else:
        ddb = boto3.resource('dynamodb', endpoint_url='http://localhost:8000')

    ddb_table = ddb.Table(table_name)
    return ddb_table


def filter_expired_items(items):
    """Filter out items that have expired based on expiry_time."""
    now = datetime.now().timestamp()
    filtered = []
    for item in items:
        expiry_time = item.get('expiry_time')
        if expiry_time is None or expiry_time == '':
            filtered.append(item)
        elif float(expiry_time) > now:
            filtered.append(item)
    return filtered


class DdbChat():
    def putComment(self, table, name, comment, chat_room, ttl_option='never'):
        logging.info('PutComments params : %s %s %s %s %s', table, name, comment, chat_room, ttl_option)
        now = datetime.now().timestamp()
        now_str = str(now)

        ttl_seconds = TTL_OPTIONS.get(ttl_option)
        expiry_time = ''
        if ttl_seconds is not None:
            expiry_time = str(now + ttl_seconds)

        result = table.put_item(
            Item={
                'name': name,
                'time': now_str,
                'comment': comment,
                'chat_room': chat_room,
                'expiry_time': expiry_time
            },
            ReturnValues='ALL_OLD',
            ReturnConsumedCapacity='TOTAL',
            ExpressionAttributeNames={'#T': 'time', '#N': 'name'},
            ConditionExpression='attribute_not_exists(#T) And attribute_not_exists(#N)'
        )
        result['time'] = now_str
        logging.info('put_item result :' + str(result))

        return result

    def getLatestComments(self, table, chat_room, item_count):
        logging.info('getLatestComments params : %s %s', table, chat_room)

        response = table.query(
            IndexName='chat_room_time_idx',
            Select='ALL_ATTRIBUTES',
            KeyConditionExpression=Key('chat_room').eq(chat_room),
            ScanIndexForward=False,
            Limit=item_count * 2
        )

        filtered_items = filter_expired_items(response['Items'])[:item_count]
        response['Items'] = filtered_items
        return response

    def getRangeComments(self, table, chat_room, position):
        logging.info('getRangeComments params : %s %s %s', table, chat_room, str(position))

        result = []

        response = table.query(
            IndexName='chat_room_time_idx',
            Select='ALL_ATTRIBUTES',
            KeyConditionExpression=Key('chat_room').eq(chat_room) & Key('time').gt(position),
            ScanIndexForward=False
        )
        for index, item in enumerate(response['Items']):
            result.append(item)

        while 'LastEvaluatedKey' in response:
            print('LastEvaluatedKey Hit!!!')
            response = table.query(
                IndexName='chat_room_time_idx',
                Select='ALL_ATTRIBUTES',
                KeyConditionExpression=Key('chat_room').eq(chat_room) & Key('time').gt(position),
                ScanIndexForward=False,
                ExclusiveStartKey=response['LastEvaluatedKey']
            )

            for index, item in enumerate(response['Items']):
                result.append(item)

        return filter_expired_items(result)

    def getAllComments(self, table, chat_room):
        logging.info('getAllComments params : %s %s', table, chat_room)

        result = []

        response = table.query(
            IndexName='chat_room_time_idx',
            Select='ALL_ATTRIBUTES',
            KeyConditionExpression=Key('chat_room').eq(chat_room),
            ScanIndexForward=False
        )

        for index, item in enumerate(response['Items']):
            result.append(item)

        while 'LastEvaluatedKey' in response:
            print('LastEvaluatedKey Hit!!!')
            response = table.query(
                IndexName='chat_room_time_idx',
                Select='ALL_ATTRIBUTES',
                KeyConditionExpression=Key('chat_room').eq(chat_room),
                ScanIndexForward=False,
                ExclusiveStartKey=response['LastEvaluatedKey']
            )

            for index, item in enumerate(response['Items']):
                result.append(item)

        return filter_expired_items(result)


"""
if __name__ == "__main__":
    ddb = DdbChat()
    table = ddb.createConnection('chat')

    name = 'oranie'
    comment = 'チャットシステムです'
    chat_room = 'chat'

    ddb.putComment(table, name, comment, chat_room)
    result = ddb.getLatestComments(table, chat_room)

    list = result['Items']
    for index, item in enumerate(list):
        logging.info(f"id: {str(index)} name: {item['name']} time: {str(item['time'])} comment: {item['comment']}")

    result = ddb.getAllComments(table, chat_room)
    for index, item in enumerate(result):
        logging.info(
            f"ALL Result id: {str(index)} name: {item['name']} time: {str(item['time'])} comment: {item['comment']}")

    logging.info(result)

    result = ddb.getRangeComments(table, chat_room, 0)

    for index, item in enumerate(result):
        logging.info(
            f"RANGE Result id: {str(index)}name: {item['name']} time: {str(item['time'])} comment: {item['comment']}")

    logging.info(result)
"""

// SPDX-License-Identifier: AGPL-3.0-or-later
use super::*;

#[test]
fn assembled_video_record_preserves_wire_bytes_and_owns_the_input() {
    let mut input = vec![0x5a; 4 * 1024 * 1024];
    let record = video_record(0x0102030405060708, 0x1234, &input);
    input.fill(0);
    assert_eq!(&record[..10], &[1, 2, 3, 4, 5, 6, 7, 8, 0x12, 0x34]);
    assert_eq!(&record[10..VIDEO_METADATA_SIZE], &[0; 6]);
    assert!(record[VIDEO_METADATA_SIZE..].iter().all(|&b| b == 0x5a));
    let address = record.as_ptr();
    let mut queue = VideoQueue::default();
    let size = record.len();
    assert_eq!(queue.push_back(record, size, VIDEO_SEND_CAPACITY), 0);
    let submitted = queue.pop_front().unwrap();
    assert_eq!(
        submitted.as_ptr(),
        address,
        "submission must move the original record"
    );
    assert_eq!(queue.bytes, 0);
}

#[test]
fn variable_size_video_overflow_counts_every_eviction() {
    let mut queue = VideoQueue::default();
    let quarter = VIDEO_QUEUE_BYTE_CAPACITY / 4;
    for tag in 0..4 {
        assert_eq!(queue.push_back(tag, quarter, VIDEO_RECEIVE_CAPACITY), 0);
    }
    assert_eq!(queue.push_back(4, quarter * 3, VIDEO_RECEIVE_CAPACITY), 3);
    assert_eq!(queue.bytes, quarter * 4);
    assert_eq!(queue.pop_front(), Some(3));
    assert_eq!(queue.pop_front(), Some(4));
    assert_eq!(queue.bytes, 0);
    assert!(queue.pop_front().is_none());
    // A maximum valid record still fits without changing protocol limits.
    assert_eq!(
        queue.push_back(5, VIDEO_QUEUE_BYTE_CAPACITY, VIDEO_RECEIVE_CAPACITY),
        0
    );
    assert_eq!(queue.push_back(6, 1, VIDEO_RECEIVE_CAPACITY), 1);
    assert_eq!(queue.bytes, 1);
}

#[test]
fn video_count_limit_and_front_inspection_preserve_byte_accounting() {
    for count in [VIDEO_SEND_CAPACITY, VIDEO_RECEIVE_CAPACITY] {
        let mut queue = VideoQueue::default();
        for tag in 0..count {
            assert_eq!(queue.push_back(tag, tag + 1, count), 0);
        }
        let before = queue.bytes;
        assert_eq!(queue.front(), Some(&0));
        assert_eq!(queue.bytes, before);
        assert_eq!(queue.push_back(count, 2, count), 1);
        assert_eq!(queue.bytes, before + 1);
        for tag in 1..=count {
            assert_eq!(queue.pop_front(), Some(tag));
        }
        assert_eq!(queue.bytes, 0);
    }
}

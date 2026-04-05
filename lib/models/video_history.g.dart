// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video_history.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class VideoHistoryAdapter extends TypeAdapter<VideoHistory> {
  @override
  final int typeId = 1;

  @override
  VideoHistory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return VideoHistory(
      videoId: fields[0] as String,
      title: fields[1] as String,
      thumbnailUrl: fields[2] as String,
      channelTitle: fields[3] as String,
      watchedAt: fields[4] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, VideoHistory obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.videoId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.thumbnailUrl)
      ..writeByte(3)
      ..write(obj.channelTitle)
      ..writeByte(4)
      ..write(obj.watchedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoHistoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

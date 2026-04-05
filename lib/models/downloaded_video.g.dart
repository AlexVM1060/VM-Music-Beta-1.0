// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_video.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DownloadedVideoAdapter extends TypeAdapter<DownloadedVideo> {
  @override
  final int typeId = 3;

  @override
  DownloadedVideo read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadedVideo(
      videoId: fields[0] as String,
      title: fields[1] as String,
      thumbnailUrl: fields[2] as String,
      channelTitle: fields[3] as String,
      filePath: fields[4] as String,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadedVideo obj) {
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
      ..write(obj.filePath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadedVideoAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

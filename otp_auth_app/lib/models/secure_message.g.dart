// GENERATED CODE - MANUAL ADAPTER

part of 'secure_message.dart';

class SecureMessageAdapter extends TypeAdapter<SecureMessage> {
  @override
  final int typeId = 2;

  @override
  SecureMessage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SecureMessage(
      id: fields[0] as String,
      text: fields[1] as String,
      createdAt: fields[2] as DateTime,
      authorDeviceLabel: fields[3] as String?,
    )..encryptedText = fields[1] as String;
  }

  @override
  void write(BinaryWriter writer, SecureMessage obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.encryptedText)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.authorDeviceLabel);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SecureMessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

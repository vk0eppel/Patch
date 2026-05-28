// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'api.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$PatchAppEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'PatchAppEvent()';
}


}

/// @nodoc
class $PatchAppEventCopyWith<$Res>  {
$PatchAppEventCopyWith(PatchAppEvent _, $Res Function(PatchAppEvent) __);
}


/// Adds pattern-matching-related methods to [PatchAppEvent].
extension PatchAppEventPatterns on PatchAppEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( PatchAppEvent_Message value)?  message,TResult Function( PatchAppEvent_MessageAcked value)?  messageAcked,TResult Function( PatchAppEvent_PeerUpdated value)?  peerUpdated,TResult Function( PatchAppEvent_PeerExpired value)?  peerExpired,TResult Function( PatchAppEvent_ChannelFlash value)?  channelFlash,TResult Function( PatchAppEvent_ChannelListUpdated value)?  channelListUpdated,TResult Function( PatchAppEvent_ClientNameChanged value)?  clientNameChanged,TResult Function( PatchAppEvent_PermissionDenied value)?  permissionDenied,required TResult orElse(),}){
final _that = this;
switch (_that) {
case PatchAppEvent_Message() when message != null:
return message(_that);case PatchAppEvent_MessageAcked() when messageAcked != null:
return messageAcked(_that);case PatchAppEvent_PeerUpdated() when peerUpdated != null:
return peerUpdated(_that);case PatchAppEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case PatchAppEvent_ChannelFlash() when channelFlash != null:
return channelFlash(_that);case PatchAppEvent_ChannelListUpdated() when channelListUpdated != null:
return channelListUpdated(_that);case PatchAppEvent_ClientNameChanged() when clientNameChanged != null:
return clientNameChanged(_that);case PatchAppEvent_PermissionDenied() when permissionDenied != null:
return permissionDenied(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( PatchAppEvent_Message value)  message,required TResult Function( PatchAppEvent_MessageAcked value)  messageAcked,required TResult Function( PatchAppEvent_PeerUpdated value)  peerUpdated,required TResult Function( PatchAppEvent_PeerExpired value)  peerExpired,required TResult Function( PatchAppEvent_ChannelFlash value)  channelFlash,required TResult Function( PatchAppEvent_ChannelListUpdated value)  channelListUpdated,required TResult Function( PatchAppEvent_ClientNameChanged value)  clientNameChanged,required TResult Function( PatchAppEvent_PermissionDenied value)  permissionDenied,}){
final _that = this;
switch (_that) {
case PatchAppEvent_Message():
return message(_that);case PatchAppEvent_MessageAcked():
return messageAcked(_that);case PatchAppEvent_PeerUpdated():
return peerUpdated(_that);case PatchAppEvent_PeerExpired():
return peerExpired(_that);case PatchAppEvent_ChannelFlash():
return channelFlash(_that);case PatchAppEvent_ChannelListUpdated():
return channelListUpdated(_that);case PatchAppEvent_ClientNameChanged():
return clientNameChanged(_that);case PatchAppEvent_PermissionDenied():
return permissionDenied(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( PatchAppEvent_Message value)?  message,TResult? Function( PatchAppEvent_MessageAcked value)?  messageAcked,TResult? Function( PatchAppEvent_PeerUpdated value)?  peerUpdated,TResult? Function( PatchAppEvent_PeerExpired value)?  peerExpired,TResult? Function( PatchAppEvent_ChannelFlash value)?  channelFlash,TResult? Function( PatchAppEvent_ChannelListUpdated value)?  channelListUpdated,TResult? Function( PatchAppEvent_ClientNameChanged value)?  clientNameChanged,TResult? Function( PatchAppEvent_PermissionDenied value)?  permissionDenied,}){
final _that = this;
switch (_that) {
case PatchAppEvent_Message() when message != null:
return message(_that);case PatchAppEvent_MessageAcked() when messageAcked != null:
return messageAcked(_that);case PatchAppEvent_PeerUpdated() when peerUpdated != null:
return peerUpdated(_that);case PatchAppEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that);case PatchAppEvent_ChannelFlash() when channelFlash != null:
return channelFlash(_that);case PatchAppEvent_ChannelListUpdated() when channelListUpdated != null:
return channelListUpdated(_that);case PatchAppEvent_ClientNameChanged() when clientNameChanged != null:
return clientNameChanged(_that);case PatchAppEvent_PermissionDenied() when permissionDenied != null:
return permissionDenied(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( PatchMessage field0)?  message,TResult Function( String messageId,  String peerId)?  messageAcked,TResult Function( PeerPresence field0)?  peerUpdated,TResult Function( String peerId)?  peerExpired,TResult Function( ChannelFlash field0)?  channelFlash,TResult Function()?  channelListUpdated,TResult Function( String name)?  clientNameChanged,TResult Function( String context)?  permissionDenied,required TResult orElse(),}) {final _that = this;
switch (_that) {
case PatchAppEvent_Message() when message != null:
return message(_that.field0);case PatchAppEvent_MessageAcked() when messageAcked != null:
return messageAcked(_that.messageId,_that.peerId);case PatchAppEvent_PeerUpdated() when peerUpdated != null:
return peerUpdated(_that.field0);case PatchAppEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case PatchAppEvent_ChannelFlash() when channelFlash != null:
return channelFlash(_that.field0);case PatchAppEvent_ChannelListUpdated() when channelListUpdated != null:
return channelListUpdated();case PatchAppEvent_ClientNameChanged() when clientNameChanged != null:
return clientNameChanged(_that.name);case PatchAppEvent_PermissionDenied() when permissionDenied != null:
return permissionDenied(_that.context);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( PatchMessage field0)  message,required TResult Function( String messageId,  String peerId)  messageAcked,required TResult Function( PeerPresence field0)  peerUpdated,required TResult Function( String peerId)  peerExpired,required TResult Function( ChannelFlash field0)  channelFlash,required TResult Function()  channelListUpdated,required TResult Function( String name)  clientNameChanged,required TResult Function( String context)  permissionDenied,}) {final _that = this;
switch (_that) {
case PatchAppEvent_Message():
return message(_that.field0);case PatchAppEvent_MessageAcked():
return messageAcked(_that.messageId,_that.peerId);case PatchAppEvent_PeerUpdated():
return peerUpdated(_that.field0);case PatchAppEvent_PeerExpired():
return peerExpired(_that.peerId);case PatchAppEvent_ChannelFlash():
return channelFlash(_that.field0);case PatchAppEvent_ChannelListUpdated():
return channelListUpdated();case PatchAppEvent_ClientNameChanged():
return clientNameChanged(_that.name);case PatchAppEvent_PermissionDenied():
return permissionDenied(_that.context);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( PatchMessage field0)?  message,TResult? Function( String messageId,  String peerId)?  messageAcked,TResult? Function( PeerPresence field0)?  peerUpdated,TResult? Function( String peerId)?  peerExpired,TResult? Function( ChannelFlash field0)?  channelFlash,TResult? Function()?  channelListUpdated,TResult? Function( String name)?  clientNameChanged,TResult? Function( String context)?  permissionDenied,}) {final _that = this;
switch (_that) {
case PatchAppEvent_Message() when message != null:
return message(_that.field0);case PatchAppEvent_MessageAcked() when messageAcked != null:
return messageAcked(_that.messageId,_that.peerId);case PatchAppEvent_PeerUpdated() when peerUpdated != null:
return peerUpdated(_that.field0);case PatchAppEvent_PeerExpired() when peerExpired != null:
return peerExpired(_that.peerId);case PatchAppEvent_ChannelFlash() when channelFlash != null:
return channelFlash(_that.field0);case PatchAppEvent_ChannelListUpdated() when channelListUpdated != null:
return channelListUpdated();case PatchAppEvent_ClientNameChanged() when clientNameChanged != null:
return clientNameChanged(_that.name);case PatchAppEvent_PermissionDenied() when permissionDenied != null:
return permissionDenied(_that.context);case _:
  return null;

}
}

}

/// @nodoc


class PatchAppEvent_Message extends PatchAppEvent {
  const PatchAppEvent_Message(this.field0): super._();
  

 final  PatchMessage field0;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_MessageCopyWith<PatchAppEvent_Message> get copyWith => _$PatchAppEvent_MessageCopyWithImpl<PatchAppEvent_Message>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_Message&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'PatchAppEvent.message(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_MessageCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_MessageCopyWith(PatchAppEvent_Message value, $Res Function(PatchAppEvent_Message) _then) = _$PatchAppEvent_MessageCopyWithImpl;
@useResult
$Res call({
 PatchMessage field0
});




}
/// @nodoc
class _$PatchAppEvent_MessageCopyWithImpl<$Res>
    implements $PatchAppEvent_MessageCopyWith<$Res> {
  _$PatchAppEvent_MessageCopyWithImpl(this._self, this._then);

  final PatchAppEvent_Message _self;
  final $Res Function(PatchAppEvent_Message) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(PatchAppEvent_Message(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PatchMessage,
  ));
}


}

/// @nodoc


class PatchAppEvent_MessageAcked extends PatchAppEvent {
  const PatchAppEvent_MessageAcked({required this.messageId, required this.peerId}): super._();
  

 final  String messageId;
 final  String peerId;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_MessageAckedCopyWith<PatchAppEvent_MessageAcked> get copyWith => _$PatchAppEvent_MessageAckedCopyWithImpl<PatchAppEvent_MessageAcked>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_MessageAcked&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,messageId,peerId);

@override
String toString() {
  return 'PatchAppEvent.messageAcked(messageId: $messageId, peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_MessageAckedCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_MessageAckedCopyWith(PatchAppEvent_MessageAcked value, $Res Function(PatchAppEvent_MessageAcked) _then) = _$PatchAppEvent_MessageAckedCopyWithImpl;
@useResult
$Res call({
 String messageId, String peerId
});




}
/// @nodoc
class _$PatchAppEvent_MessageAckedCopyWithImpl<$Res>
    implements $PatchAppEvent_MessageAckedCopyWith<$Res> {
  _$PatchAppEvent_MessageAckedCopyWithImpl(this._self, this._then);

  final PatchAppEvent_MessageAcked _self;
  final $Res Function(PatchAppEvent_MessageAcked) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? messageId = null,Object? peerId = null,}) {
  return _then(PatchAppEvent_MessageAcked(
messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class PatchAppEvent_PeerUpdated extends PatchAppEvent {
  const PatchAppEvent_PeerUpdated(this.field0): super._();
  

 final  PeerPresence field0;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_PeerUpdatedCopyWith<PatchAppEvent_PeerUpdated> get copyWith => _$PatchAppEvent_PeerUpdatedCopyWithImpl<PatchAppEvent_PeerUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_PeerUpdated&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'PatchAppEvent.peerUpdated(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_PeerUpdatedCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_PeerUpdatedCopyWith(PatchAppEvent_PeerUpdated value, $Res Function(PatchAppEvent_PeerUpdated) _then) = _$PatchAppEvent_PeerUpdatedCopyWithImpl;
@useResult
$Res call({
 PeerPresence field0
});




}
/// @nodoc
class _$PatchAppEvent_PeerUpdatedCopyWithImpl<$Res>
    implements $PatchAppEvent_PeerUpdatedCopyWith<$Res> {
  _$PatchAppEvent_PeerUpdatedCopyWithImpl(this._self, this._then);

  final PatchAppEvent_PeerUpdated _self;
  final $Res Function(PatchAppEvent_PeerUpdated) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(PatchAppEvent_PeerUpdated(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PeerPresence,
  ));
}


}

/// @nodoc


class PatchAppEvent_PeerExpired extends PatchAppEvent {
  const PatchAppEvent_PeerExpired({required this.peerId}): super._();
  

 final  String peerId;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_PeerExpiredCopyWith<PatchAppEvent_PeerExpired> get copyWith => _$PatchAppEvent_PeerExpiredCopyWithImpl<PatchAppEvent_PeerExpired>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_PeerExpired&&(identical(other.peerId, peerId) || other.peerId == peerId));
}


@override
int get hashCode => Object.hash(runtimeType,peerId);

@override
String toString() {
  return 'PatchAppEvent.peerExpired(peerId: $peerId)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_PeerExpiredCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_PeerExpiredCopyWith(PatchAppEvent_PeerExpired value, $Res Function(PatchAppEvent_PeerExpired) _then) = _$PatchAppEvent_PeerExpiredCopyWithImpl;
@useResult
$Res call({
 String peerId
});




}
/// @nodoc
class _$PatchAppEvent_PeerExpiredCopyWithImpl<$Res>
    implements $PatchAppEvent_PeerExpiredCopyWith<$Res> {
  _$PatchAppEvent_PeerExpiredCopyWithImpl(this._self, this._then);

  final PatchAppEvent_PeerExpired _self;
  final $Res Function(PatchAppEvent_PeerExpired) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? peerId = null,}) {
  return _then(PatchAppEvent_PeerExpired(
peerId: null == peerId ? _self.peerId : peerId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class PatchAppEvent_ChannelFlash extends PatchAppEvent {
  const PatchAppEvent_ChannelFlash(this.field0): super._();
  

 final  ChannelFlash field0;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_ChannelFlashCopyWith<PatchAppEvent_ChannelFlash> get copyWith => _$PatchAppEvent_ChannelFlashCopyWithImpl<PatchAppEvent_ChannelFlash>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_ChannelFlash&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'PatchAppEvent.channelFlash(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_ChannelFlashCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_ChannelFlashCopyWith(PatchAppEvent_ChannelFlash value, $Res Function(PatchAppEvent_ChannelFlash) _then) = _$PatchAppEvent_ChannelFlashCopyWithImpl;
@useResult
$Res call({
 ChannelFlash field0
});




}
/// @nodoc
class _$PatchAppEvent_ChannelFlashCopyWithImpl<$Res>
    implements $PatchAppEvent_ChannelFlashCopyWith<$Res> {
  _$PatchAppEvent_ChannelFlashCopyWithImpl(this._self, this._then);

  final PatchAppEvent_ChannelFlash _self;
  final $Res Function(PatchAppEvent_ChannelFlash) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(PatchAppEvent_ChannelFlash(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as ChannelFlash,
  ));
}


}

/// @nodoc


class PatchAppEvent_ChannelListUpdated extends PatchAppEvent {
  const PatchAppEvent_ChannelListUpdated(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_ChannelListUpdated);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'PatchAppEvent.channelListUpdated()';
}


}




/// @nodoc


class PatchAppEvent_ClientNameChanged extends PatchAppEvent {
  const PatchAppEvent_ClientNameChanged({required this.name}): super._();
  

 final  String name;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_ClientNameChangedCopyWith<PatchAppEvent_ClientNameChanged> get copyWith => _$PatchAppEvent_ClientNameChangedCopyWithImpl<PatchAppEvent_ClientNameChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_ClientNameChanged&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode => Object.hash(runtimeType,name);

@override
String toString() {
  return 'PatchAppEvent.clientNameChanged(name: $name)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_ClientNameChangedCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_ClientNameChangedCopyWith(PatchAppEvent_ClientNameChanged value, $Res Function(PatchAppEvent_ClientNameChanged) _then) = _$PatchAppEvent_ClientNameChangedCopyWithImpl;
@useResult
$Res call({
 String name
});




}
/// @nodoc
class _$PatchAppEvent_ClientNameChangedCopyWithImpl<$Res>
    implements $PatchAppEvent_ClientNameChangedCopyWith<$Res> {
  _$PatchAppEvent_ClientNameChangedCopyWithImpl(this._self, this._then);

  final PatchAppEvent_ClientNameChanged _self;
  final $Res Function(PatchAppEvent_ClientNameChanged) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,}) {
  return _then(PatchAppEvent_ClientNameChanged(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class PatchAppEvent_PermissionDenied extends PatchAppEvent {
  const PatchAppEvent_PermissionDenied({required this.context}): super._();
  

 final  String context;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PatchAppEvent_PermissionDeniedCopyWith<PatchAppEvent_PermissionDenied> get copyWith => _$PatchAppEvent_PermissionDeniedCopyWithImpl<PatchAppEvent_PermissionDenied>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PatchAppEvent_PermissionDenied&&(identical(other.context, context) || other.context == context));
}


@override
int get hashCode => Object.hash(runtimeType,context);

@override
String toString() {
  return 'PatchAppEvent.permissionDenied(context: $context)';
}


}

/// @nodoc
abstract mixin class $PatchAppEvent_PermissionDeniedCopyWith<$Res> implements $PatchAppEventCopyWith<$Res> {
  factory $PatchAppEvent_PermissionDeniedCopyWith(PatchAppEvent_PermissionDenied value, $Res Function(PatchAppEvent_PermissionDenied) _then) = _$PatchAppEvent_PermissionDeniedCopyWithImpl;
@useResult
$Res call({
 String context
});




}
/// @nodoc
class _$PatchAppEvent_PermissionDeniedCopyWithImpl<$Res>
    implements $PatchAppEvent_PermissionDeniedCopyWith<$Res> {
  _$PatchAppEvent_PermissionDeniedCopyWithImpl(this._self, this._then);

  final PatchAppEvent_PermissionDenied _self;
  final $Res Function(PatchAppEvent_PermissionDenied) _then;

/// Create a copy of PatchAppEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? context = null,}) {
  return _then(PatchAppEvent_PermissionDenied(
context: null == context ? _self.context : context // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on

// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'channel.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$MacroImportOutcome {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MacroImportOutcome);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MacroImportOutcome()';
}


}

/// @nodoc
class $MacroImportOutcomeCopyWith<$Res>  {
$MacroImportOutcomeCopyWith(MacroImportOutcome _, $Res Function(MacroImportOutcome) __);
}


/// Adds pattern-matching-related methods to [MacroImportOutcome].
extension MacroImportOutcomePatterns on MacroImportOutcome {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( MacroImportOutcome_AlreadyHave value)?  alreadyHave,TResult Function( MacroImportOutcome_Added value)?  added,TResult Function( MacroImportOutcome_AddedBindingDropped value)?  addedBindingDropped,TResult Function( MacroImportOutcome_Skipped value)?  skipped,required TResult orElse(),}){
final _that = this;
switch (_that) {
case MacroImportOutcome_AlreadyHave() when alreadyHave != null:
return alreadyHave(_that);case MacroImportOutcome_Added() when added != null:
return added(_that);case MacroImportOutcome_AddedBindingDropped() when addedBindingDropped != null:
return addedBindingDropped(_that);case MacroImportOutcome_Skipped() when skipped != null:
return skipped(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( MacroImportOutcome_AlreadyHave value)  alreadyHave,required TResult Function( MacroImportOutcome_Added value)  added,required TResult Function( MacroImportOutcome_AddedBindingDropped value)  addedBindingDropped,required TResult Function( MacroImportOutcome_Skipped value)  skipped,}){
final _that = this;
switch (_that) {
case MacroImportOutcome_AlreadyHave():
return alreadyHave(_that);case MacroImportOutcome_Added():
return added(_that);case MacroImportOutcome_AddedBindingDropped():
return addedBindingDropped(_that);case MacroImportOutcome_Skipped():
return skipped(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( MacroImportOutcome_AlreadyHave value)?  alreadyHave,TResult? Function( MacroImportOutcome_Added value)?  added,TResult? Function( MacroImportOutcome_AddedBindingDropped value)?  addedBindingDropped,TResult? Function( MacroImportOutcome_Skipped value)?  skipped,}){
final _that = this;
switch (_that) {
case MacroImportOutcome_AlreadyHave() when alreadyHave != null:
return alreadyHave(_that);case MacroImportOutcome_Added() when added != null:
return added(_that);case MacroImportOutcome_AddedBindingDropped() when addedBindingDropped != null:
return addedBindingDropped(_that);case MacroImportOutcome_Skipped() when skipped != null:
return skipped(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String label)?  alreadyHave,TResult Function( MacroMessage msg)?  added,TResult Function( MacroMessage msg,  String reason)?  addedBindingDropped,TResult Function( String label,  String reason)?  skipped,required TResult orElse(),}) {final _that = this;
switch (_that) {
case MacroImportOutcome_AlreadyHave() when alreadyHave != null:
return alreadyHave(_that.label);case MacroImportOutcome_Added() when added != null:
return added(_that.msg);case MacroImportOutcome_AddedBindingDropped() when addedBindingDropped != null:
return addedBindingDropped(_that.msg,_that.reason);case MacroImportOutcome_Skipped() when skipped != null:
return skipped(_that.label,_that.reason);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String label)  alreadyHave,required TResult Function( MacroMessage msg)  added,required TResult Function( MacroMessage msg,  String reason)  addedBindingDropped,required TResult Function( String label,  String reason)  skipped,}) {final _that = this;
switch (_that) {
case MacroImportOutcome_AlreadyHave():
return alreadyHave(_that.label);case MacroImportOutcome_Added():
return added(_that.msg);case MacroImportOutcome_AddedBindingDropped():
return addedBindingDropped(_that.msg,_that.reason);case MacroImportOutcome_Skipped():
return skipped(_that.label,_that.reason);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String label)?  alreadyHave,TResult? Function( MacroMessage msg)?  added,TResult? Function( MacroMessage msg,  String reason)?  addedBindingDropped,TResult? Function( String label,  String reason)?  skipped,}) {final _that = this;
switch (_that) {
case MacroImportOutcome_AlreadyHave() when alreadyHave != null:
return alreadyHave(_that.label);case MacroImportOutcome_Added() when added != null:
return added(_that.msg);case MacroImportOutcome_AddedBindingDropped() when addedBindingDropped != null:
return addedBindingDropped(_that.msg,_that.reason);case MacroImportOutcome_Skipped() when skipped != null:
return skipped(_that.label,_that.reason);case _:
  return null;

}
}

}

/// @nodoc


class MacroImportOutcome_AlreadyHave extends MacroImportOutcome {
  const MacroImportOutcome_AlreadyHave({required this.label}): super._();
  

 final  String label;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MacroImportOutcome_AlreadyHaveCopyWith<MacroImportOutcome_AlreadyHave> get copyWith => _$MacroImportOutcome_AlreadyHaveCopyWithImpl<MacroImportOutcome_AlreadyHave>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MacroImportOutcome_AlreadyHave&&(identical(other.label, label) || other.label == label));
}


@override
int get hashCode => Object.hash(runtimeType,label);

@override
String toString() {
  return 'MacroImportOutcome.alreadyHave(label: $label)';
}


}

/// @nodoc
abstract mixin class $MacroImportOutcome_AlreadyHaveCopyWith<$Res> implements $MacroImportOutcomeCopyWith<$Res> {
  factory $MacroImportOutcome_AlreadyHaveCopyWith(MacroImportOutcome_AlreadyHave value, $Res Function(MacroImportOutcome_AlreadyHave) _then) = _$MacroImportOutcome_AlreadyHaveCopyWithImpl;
@useResult
$Res call({
 String label
});




}
/// @nodoc
class _$MacroImportOutcome_AlreadyHaveCopyWithImpl<$Res>
    implements $MacroImportOutcome_AlreadyHaveCopyWith<$Res> {
  _$MacroImportOutcome_AlreadyHaveCopyWithImpl(this._self, this._then);

  final MacroImportOutcome_AlreadyHave _self;
  final $Res Function(MacroImportOutcome_AlreadyHave) _then;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? label = null,}) {
  return _then(MacroImportOutcome_AlreadyHave(
label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MacroImportOutcome_Added extends MacroImportOutcome {
  const MacroImportOutcome_Added({required this.msg}): super._();
  

 final  MacroMessage msg;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MacroImportOutcome_AddedCopyWith<MacroImportOutcome_Added> get copyWith => _$MacroImportOutcome_AddedCopyWithImpl<MacroImportOutcome_Added>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MacroImportOutcome_Added&&(identical(other.msg, msg) || other.msg == msg));
}


@override
int get hashCode => Object.hash(runtimeType,msg);

@override
String toString() {
  return 'MacroImportOutcome.added(msg: $msg)';
}


}

/// @nodoc
abstract mixin class $MacroImportOutcome_AddedCopyWith<$Res> implements $MacroImportOutcomeCopyWith<$Res> {
  factory $MacroImportOutcome_AddedCopyWith(MacroImportOutcome_Added value, $Res Function(MacroImportOutcome_Added) _then) = _$MacroImportOutcome_AddedCopyWithImpl;
@useResult
$Res call({
 MacroMessage msg
});




}
/// @nodoc
class _$MacroImportOutcome_AddedCopyWithImpl<$Res>
    implements $MacroImportOutcome_AddedCopyWith<$Res> {
  _$MacroImportOutcome_AddedCopyWithImpl(this._self, this._then);

  final MacroImportOutcome_Added _self;
  final $Res Function(MacroImportOutcome_Added) _then;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? msg = null,}) {
  return _then(MacroImportOutcome_Added(
msg: null == msg ? _self.msg : msg // ignore: cast_nullable_to_non_nullable
as MacroMessage,
  ));
}


}

/// @nodoc


class MacroImportOutcome_AddedBindingDropped extends MacroImportOutcome {
  const MacroImportOutcome_AddedBindingDropped({required this.msg, required this.reason}): super._();
  

 final  MacroMessage msg;
 final  String reason;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MacroImportOutcome_AddedBindingDroppedCopyWith<MacroImportOutcome_AddedBindingDropped> get copyWith => _$MacroImportOutcome_AddedBindingDroppedCopyWithImpl<MacroImportOutcome_AddedBindingDropped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MacroImportOutcome_AddedBindingDropped&&(identical(other.msg, msg) || other.msg == msg)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,msg,reason);

@override
String toString() {
  return 'MacroImportOutcome.addedBindingDropped(msg: $msg, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $MacroImportOutcome_AddedBindingDroppedCopyWith<$Res> implements $MacroImportOutcomeCopyWith<$Res> {
  factory $MacroImportOutcome_AddedBindingDroppedCopyWith(MacroImportOutcome_AddedBindingDropped value, $Res Function(MacroImportOutcome_AddedBindingDropped) _then) = _$MacroImportOutcome_AddedBindingDroppedCopyWithImpl;
@useResult
$Res call({
 MacroMessage msg, String reason
});




}
/// @nodoc
class _$MacroImportOutcome_AddedBindingDroppedCopyWithImpl<$Res>
    implements $MacroImportOutcome_AddedBindingDroppedCopyWith<$Res> {
  _$MacroImportOutcome_AddedBindingDroppedCopyWithImpl(this._self, this._then);

  final MacroImportOutcome_AddedBindingDropped _self;
  final $Res Function(MacroImportOutcome_AddedBindingDropped) _then;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? msg = null,Object? reason = null,}) {
  return _then(MacroImportOutcome_AddedBindingDropped(
msg: null == msg ? _self.msg : msg // ignore: cast_nullable_to_non_nullable
as MacroMessage,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MacroImportOutcome_Skipped extends MacroImportOutcome {
  const MacroImportOutcome_Skipped({required this.label, required this.reason}): super._();
  

 final  String label;
 final  String reason;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MacroImportOutcome_SkippedCopyWith<MacroImportOutcome_Skipped> get copyWith => _$MacroImportOutcome_SkippedCopyWithImpl<MacroImportOutcome_Skipped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MacroImportOutcome_Skipped&&(identical(other.label, label) || other.label == label)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,label,reason);

@override
String toString() {
  return 'MacroImportOutcome.skipped(label: $label, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $MacroImportOutcome_SkippedCopyWith<$Res> implements $MacroImportOutcomeCopyWith<$Res> {
  factory $MacroImportOutcome_SkippedCopyWith(MacroImportOutcome_Skipped value, $Res Function(MacroImportOutcome_Skipped) _then) = _$MacroImportOutcome_SkippedCopyWithImpl;
@useResult
$Res call({
 String label, String reason
});




}
/// @nodoc
class _$MacroImportOutcome_SkippedCopyWithImpl<$Res>
    implements $MacroImportOutcome_SkippedCopyWith<$Res> {
  _$MacroImportOutcome_SkippedCopyWithImpl(this._self, this._then);

  final MacroImportOutcome_Skipped _self;
  final $Res Function(MacroImportOutcome_Skipped) _then;

/// Create a copy of MacroImportOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? label = null,Object? reason = null,}) {
  return _then(MacroImportOutcome_Skipped(
label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on

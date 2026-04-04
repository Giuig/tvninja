# Keep class structure and inner relationships
-keepattributes *Annotation*,InnerClasses,EnclosingMethod

# Prevent crashes by ensuring these aren't removed
-keep class **.HI { *; }
-keep class **.hI { *; }

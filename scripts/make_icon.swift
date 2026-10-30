// Draws the app icon set. Usage: swift scripts/make_icon.swift Screening/Assets.xcassets/AppIcon.appiconset
import AppKit
let out = CommandLine.arguments[1]
var images: [[String:String]] = []
for pt in [16,32,128,256,512] { for sc in [1,2] {
  let px = pt*sc
  let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px,pixelsHigh:px,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px), inset = s*0.1, r = CGRect(x:inset,y:inset,width:s-2*inset,height:s-2*inset)
  let path = NSBezierPath(roundedRect:r,xRadius:r.width*0.225,yRadius:r.width*0.225)
  NSGradient(starting:NSColor(srgbRed:0.36,green:0.72,blue:1,alpha:1),ending:NSColor(srgbRed:0.05,green:0.32,blue:0.92,alpha:1))!.draw(in:path,angle:-90)
  let w = r.width*0.62, cfg = NSImage.SymbolConfiguration(pointSize:w*0.8,weight:.regular).applying(.init(paletteColors:[.white]))
  let sym = NSImage(systemSymbolName:"camera.viewfinder",accessibilityDescription:nil)!.withSymbolConfiguration(cfg)!
  let sz = sym.size, f = min(w/sz.width,w/sz.height), d = CGSize(width:sz.width*f,height:sz.height*f)
  sym.draw(in:CGRect(x:r.midX-d.width/2,y:r.midY-d.height/2,width:d.width,height:d.height))
  NSGraphicsContext.restoreGraphicsState()
  let name = "icon_\(pt)x\(pt)@\(sc)x.png"
  try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:out+"/"+name))
  images.append(["idiom":"mac","size":"\(pt)x\(pt)","scale":"\(sc)x","filename":name])
}}
let json = try! JSONSerialization.data(withJSONObject:["images":images,"info":["author":"xcode","version":1]],options:.prettyPrinted)
try! json.write(to:URL(fileURLWithPath:out+"/Contents.json"))

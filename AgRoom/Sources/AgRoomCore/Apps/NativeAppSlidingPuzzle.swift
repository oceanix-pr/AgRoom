import Foundation

extension NativeAppTemplates {
    /// Classic "横刀立马" layout, using only the public DSL and local board rules.
    public static func slidingPuzzle() throws -> NativeAppDefinition {
        try NativeAppDefinition.decode(Data(slidingPuzzleJSON.utf8))
    }

    private static let slidingPuzzleJSON = #"""
    {
      "manifest":{"id":"sliding-puzzle","version":1,"dslVersion":4,"nameKey":"name","summaryKey":"summary","icon":"square.grid.2x2","width":560,"height":840},
      "i18n":{
        "en":{"name":"Klotski","summary":"Slide Cao Cao to the bottom-center goal. Your progress is saved in this app.","instructions":"Slide blocks horizontally or vertically to move Cao Cao onto the dashed goal. Each straight slide counts as one move.","undo":"Undo","redo":"Redo","restart":"Start Over","cao":"Cao Cao","guan":"Guan Yu","zhang":"Zhang Fei","zhao":"Zhao Yun","ma":"Ma Chao","huang":"Huang Zhong","soldier-1":"Soldier 1","soldier-2":"Soldier 2","soldier-3":"Soldier 3","soldier-4":"Soldier 4"},
        "zh-Hans":{"name":"华容道","summary":"移动曹操到下方中央出口，游戏进度保存在本应用。","instructions":"横向或纵向滑动棋子，将曹操移到虚线目标区域。一次直线滑动计一步。","undo":"撤销","redo":"重做","restart":"重新开始","cao":"曹操","guan":"关羽","zhang":"张飞","zhao":"赵云","ma":"马超","huang":"黄忠","soldier-1":"卒一","soldier-2":"卒二","soldier-3":"卒三","soldier-4":"卒四"},
        "zh-Hant":{"name":"華容道","summary":"移動曹操到下方中央出口，遊戲進度儲存在本應用程式。","instructions":"橫向或縱向滑動棋子，將曹操移到虛線目標區域。一次直線滑動計一步。","undo":"復原","redo":"重做","restart":"重新開始","cao":"曹操","guan":"關羽","zhang":"張飛","zhao":"趙雲","ma":"馬超","huang":"黃忠","soldier-1":"卒一","soldier-2":"卒二","soldier-3":"卒三","soldier-4":"卒四"}
      },
      "state":{},"dataSources":{},
      "boards":{"puzzle":{"columns":4,"rows":5,"persistent":true,
        "pieces":[
          {"id":"cao","labelKey":"cao","x":1,"y":0,"width":2,"height":2},
          {"id":"guan","labelKey":"guan","x":1,"y":2,"width":2,"height":1},
          {"id":"zhang","labelKey":"zhang","x":0,"y":0,"width":1,"height":2},
          {"id":"zhao","labelKey":"zhao","x":3,"y":0,"width":1,"height":2},
          {"id":"ma","labelKey":"ma","x":0,"y":2,"width":1,"height":2},
          {"id":"huang","labelKey":"huang","x":3,"y":2,"width":1,"height":2},
          {"id":"soldier-1","labelKey":"soldier-1","x":1,"y":3,"width":1,"height":1},
          {"id":"soldier-2","labelKey":"soldier-2","x":2,"y":3,"width":1,"height":1},
          {"id":"soldier-3","labelKey":"soldier-3","x":0,"y":4,"width":1,"height":1},
          {"id":"soldier-4","labelKey":"soldier-4","x":3,"y":4,"width":1,"height":1}
        ],"goal":{"piece":"cao","x":1,"y":3}}},
      "views":{"id":"root","type":"vstack","children":[
        {"id":"heading","type":"text","textKey":"name","style":"title"},
        {"id":"instructions","type":"text","textKey":"instructions","style":"secondary"},
        {"id":"game","type":"board","board":"puzzle"},
        {"id":"controls","type":"hstack","children":[
          {"id":"undo","type":"button","textKey":"undo","action":"undo"},
          {"id":"redo","type":"button","textKey":"redo","action":"redo"},
          {"id":"restart","type":"button","textKey":"restart","action":"restart"}
        ]}
      ]},
      "actions":{"undo":{"type":"boardUndo","board":"puzzle"},"redo":{"type":"boardRedo","board":"puzzle"},"restart":{"type":"boardReset","board":"puzzle"}}
    }
    """#
}
